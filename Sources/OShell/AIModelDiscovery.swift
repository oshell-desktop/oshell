// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

struct AIDiscoveredModel: Equatable {
    let id: String
    let name: String
}
/// A separately requested metadata lookup. It cannot access a conversation,
/// attachments, history, or another channel's credentials.
struct AIModelListRequest: Equatable {
    let url: URL
    let type: AIAPIType
    let key: String
    let timeout: TimeInterval
    init(channel: AIChannelConfiguration) throws {
        type = channel.apiType; key = channel.apiKey; timeout = TimeInterval(channel.timeout)
        var address = channel.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.contains("{model}") {
            guard type == .gemini, address.hasSuffix("/models/{model}:generateContent"), address.components(separatedBy: "{model}").count == 2 else { throw ModelError.invalid("模型模板地址不正确。") }
            address = address.replacingOccurrences(of: "{model}", with: "model-placeholder")
        }
        var validation = AISettings(); validation.endpoint = address; validation.model = "model-list"
        validation.apiType = type == .gemini ? .chatCompletions : type
        validation.apiKey = key; validation.timeout = channel.timeout
        // Validate transport and header safety without requiring a model ID.
        _ = try validation.validatedURL(); try validation.validate()
        guard var parts = URLComponents(string: address) else { throw ModelError.invalid("接口地址无效。") }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        if path.isEmpty || path == "/" { path = type == .gemini ? "/v1beta/models" : "/v1/models" }
        else if path.hasSuffix("/models") { /* Explicit list endpoint. */ }
        else if path.range(of: "/v[0-9]+(?:alpha[0-9]*|beta[0-9]*)?$", options: .regularExpression) != nil { path += "/models" }
        else if type == .gemini, path.hasSuffix(":generateContent"), let models = path.range(of: "/models/", options: .backwards) {
            path = String(path[..<models.lowerBound]) + "/models"
        } else if type == .anthropic && (path.hasSuffix("/anthropic") || path.hasSuffix("/coding")) { path += "/v1/models" }
        else {
            let suffix = type == .chatCompletions ? "/chat/completions" : type == .responses ? "/responses" : "/messages"
            guard type != .gemini, path.hasSuffix(suffix) else { throw ModelError.invalid("无法从该地址确定模型列表入口。请填写基础地址（如 /v1）或标准接口地址；也可手动添加模型。") }
            path = String(path.dropLast(suffix.count)) + "/models"
        }
        parts.percentEncodedPath = path
        guard let resolved = parts.url else { throw ModelError.invalid("模型列表地址无效。") }; url = resolved
    }
    func request(cursor: String?) throws -> URLRequest {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem]()
        if type == .anthropic { query.append(.init(name: "limit", value: "100")) }
        if type == .gemini { query.append(.init(name: "pageSize", value: "100")) }
        if let cursor {
            guard cursor.count <= 2048, !cursor.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), key.isEmpty || !cursor.contains(key) else { throw ModelError.invalid("模型列表分页标记无效。") }
            query.append(.init(name: type == .gemini ? "pageToken" : "after_id", value: cursor))
        }
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(timeout, 60))
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AIRequest.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in type.headers(key: key) where name != "Content-Type" { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
    func parse(_ data: Data) throws -> (models: [AIDiscoveredModel], cursor: String?) {
        let invalid = ModelError.invalid("返回内容不是受支持的模型列表，请检查接口地址；现有配置未修改。")
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["error"] == nil || object["error"] is NSNull,
              let rows = object[type == .gemini ? "models" : "data"] as? [[String: Any]] else { throw invalid }
        var models = [AIDiscoveredModel]()
        for row in rows {
            if type == .gemini {
                guard let methods = row["supportedGenerationMethods"] as? [String], methods.contains("generateContent") else { continue }
            }
            if row["lifecycle"] as? String == "retired" { continue }
            guard var id = row[type == .gemini ? "name" : "id"] as? String else { continue }
            if type == .gemini, id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
            guard !id.isEmpty, id.count <= 200, !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  key.isEmpty || !id.contains(key) else { continue }
            if type == .gemini, id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$", options: .regularExpression) == nil { continue }
            var name = (row[type == .gemini ? "displayName" : "display_name"] as? String) ?? ""
            if !key.isEmpty { name = name.replacingOccurrences(of: key, with: "[已遮盖密钥]") }
            name = String(String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(80))
            models.append(.init(id: id, name: name))
        }
        var cursor: String?
        if type == .gemini {
            if let token = object["nextPageToken"], !(token is NSNull) {
                guard let value = token as? String else { throw invalid }; cursor = value.isEmpty ? nil : value
            }
        } else if object["has_more"] as? Bool == true {
            guard type == .anthropic, let value = object["last_id"] as? String, !value.isEmpty else { throw ModelError.invalid("该服务的模型分页格式不受支持，可手动添加模型。") }
            cursor = value
        }
        return (models, cursor)
    }
}

/// UI-initiated GETs only, with an immutable channel, bounded pagination and no
/// cookies, redirects, retry, or server-supplied next-page URLs.
final class AIModelDiscoveryClient: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private var session: URLSession?, timer: Timer?, completion: ((Result<[AIDiscoveredModel], Error>) -> Void)?
    private var source: AIModelListRequest!, data = Data(), totalBytes = 0, page = 0, status = 0
    private var models = [AIDiscoveredModel](), ids = Set<String>(), cursors = Set<String>(), finished = false
    func start(_ request: AIModelListRequest, completion: @escaping (Result<[AIDiscoveredModel], Error>) -> Void) throws {
        guard Thread.isMainThread, session == nil, !finished else { throw ModelError.invalid("模型查询已开始或已结束。") }
        source = request; self.completion = completion
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = min(request.timeout, 60)
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        let timer = Timer(timeInterval: min(request.timeout, 60), repeats: false) { [weak self] _ in self?.finish(.failure(ModelError.invalid("获取模型列表超时，请重试或手动添加。"))) }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
        load(cursor: nil)
    }
    private func load(cursor: String?) {
        guard !finished else { return }
        do { let request = try source.request(cursor: cursor); data = Data(); status = 0; page += 1; session?.dataTask(with: request).resume() }
        catch { finish(.failure(error)) }
    }
    func cancel() { finish(.failure(ModelError.invalid("已停止获取模型列表。"))) }
    private func finish(_ result: Result<[AIDiscoveredModel], Error>) {
        guard !finished else { return }; finished = true
        timer?.invalidate(); timer = nil; session?.invalidateAndCancel(); session = nil
        let callback = completion; completion = nil; source = nil; data = Data()
        callback?(result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { completionHandler(.cancel); return }
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > 2 * 1024 * 1024 { completionHandler(.cancel); finish(.failure(ModelError.invalid("模型列表响应过大，已停止获取。"))) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !finished else { return }; totalBytes += chunk.count
        guard data.count + chunk.count <= 2 * 1024 * 1024, totalBytes <= 8 * 1024 * 1024 else { finish(.failure(ModelError.invalid("模型列表响应过大，已停止获取。"))); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        do {
            if error != nil { throw ModelError.invalid("无法获取模型列表，请检查网络或证书；现有模型未修改。") }
            guard (200...299).contains(status) else {
                let message: String
                switch status {
                case 401, 403: message = "获取模型列表的鉴权失败，请检查此渠道的密钥与权限。"
                case 404, 405, 501: message = "此渠道未提供标准模型列表接口，请手动填写模型 ID。"
                case 300...399: message = "模型列表接口返回重定向，未携带密钥跟随；请检查最终接口地址。"
                case 429: message = "模型列表请求受到限流，请稍后重试。"
                default: message = "模型列表请求失败，请检查接口地址。"
                }
                throw ModelError.invalid(message + "（HTTP \(status)）")
            }
            let response = try source.parse(data)
            for model in response.models where ids.insert(model.id).inserted { models.append(model) }
            guard models.count <= 2000 else { throw ModelError.invalid("模型列表超过 2000 项，请手动添加所需模型。") }
            if let cursor = response.cursor {
                guard page < 20, cursors.insert(cursor).inserted else { throw ModelError.invalid("模型列表分页异常或过多，已停止获取。") }
                load(cursor: cursor)
            } else { finish(.success(models)) }
        } catch { finish(.failure(error)) }
    }
}

extension AIChannelConfiguration {
    /// Work on a copy so overflow or cancellation never leaves a partial import.
    func addingDiscovered(_ choices: [AIDiscoveredModel], totalModels: Int) throws -> (channel: Self, firstIndex: Int?) {
        func normalized(_ id: String) -> String { apiType == .gemini && id.hasPrefix("models/") ? String(id.dropFirst(7)) : id }
        var result = self, first: Int?, existing = Set(models.map { normalized($0.model) })
        for choice in choices where existing.insert(normalized(choice.id)).inserted {
            if let index = result.models.firstIndex(where: { $0.model.isEmpty }) {
                result.models[index].model = choice.id
                if result.models[index].name.isEmpty { result.models[index].name = choice.name }
                if first == nil { first = index }
            } else {
                var item = AIModelConfiguration(); item.model = choice.id; item.name = choice.name
                result.models.append(item); if first == nil { first = result.models.count - 1 }
            }
        }
        guard result.models.count <= 32, totalModels + result.models.count - models.count <= 256 else { throw ModelError.invalid("每个渠道最多 32 个模型，总共最多 256 个；请减少本次选择。") }
        return (result, first)
    }
}
