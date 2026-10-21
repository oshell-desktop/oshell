// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import Security

public struct WebDAVSettings: Codable {
    public var address: String
    public var username: String
    public var password: String
    /// Stored only in this Mac's encrypted WebDAV settings, not the shared vault configuration.
    public var trustedServerCertificate: WebDAVCertificateTrust? = nil
    public init(address: String, username: String, password: String) { self.address = address; self.username = username; self.password = password }
    public func directory(allowLoopbackHTTP: Bool = false) throws -> URL {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (allowLoopbackHTTP && parts.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)),
              !username.contains(":"), !username.contains("\n"), !username.contains("\r"), !password.contains("\n"), !password.contains("\r") else {
            throw ModelError.invalid("请输入 HTTPS WebDAV 目录地址，账号密码请填写在单独字段中。")
        }
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw ModelError.invalid("WebDAV 地址无效。") }; return url
    }
}
public struct WebDAVObject {
    public let data: Data
    public let etag: String
}
public enum WebDAVFailure: Error, LocalizedError {
    case conflict, authentication, status(Int), unsafeVersion, network, tls, tooLarge, redirect
    public var errorDescription: String? {
        switch self {
        case .conflict: return "共享版本已变化，未覆盖。请重新同步并确认冲突。"
        case .authentication: return "WebDAV 身份验证失败，请检查账号、密码及应用专用密码。"
        case .status(let code): return "WebDAV 返回 HTTP \(code)。请确认目录存在且账号有读写权限。"
        case .unsafeVersion: return "服务器未提供可用的强 ETag，无法安全同步；不会无条件覆盖数据。"
        case .tls: return "WebDAV TLS 连接或证书校验失败，请检查服务器证书和 HTTPS 配置。"
        case .network: return "WebDAV 网络请求失败或超时，本地数据已保留。"
        case .tooLarge: return "WebDAV 响应超过大小限制。"
        case .redirect: return "WebDAV 地址发生重定向。请直接填写最终 HTTPS 目录地址。"
        }
    }
}
private final class DAVRequest: NSObject, URLSessionDataDelegate {
    let done = DispatchSemaphore(value: 0)
    let endpoint: URL
    let pinned: WebDAVCertificateTrust?
    init(endpoint: URL, pinned: WebDAVCertificateTrust?) { self.endpoint = endpoint; self.pinned = pinned }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        guard WebDAVCertificateTrust.normalizedHost(challenge.protectionSpace.host) == endpoint.host.map(WebDAVCertificateTrust.normalizedHost),
              challenge.protectionSpace.port == (endpoint.port ?? 443),
              let leaf = SecTrustGetCertificateAtIndex(trust, 0) else {
            error = WebDAVFailure.tls; completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let certificate = WebDAVCertificateTrust(host: challenge.protectionSpace.host, port: challenge.protectionSpace.port, certificateDER: SecCertificateCopyData(leaf) as Data)
        let pin = pinned.flatMap { $0.matches(endpoint) ? $0 : nil }
        let changed = pin.map { $0.certificateDER != certificate.certificateDER } ?? false
        let systemTrusted = WebDAVCertificateTrust.evaluate(trust)
        if !changed && systemTrusted && (pin == nil || certificate.isCurrent()) { completionHandler(.performDefaultHandling, nil); return }
        let validation = certificate.validation(trust)
        if !changed, pin != nil, validation.acceptable {
            completionHandler(.useCredential, URLCredential(trust: trust)); return
        }
        error = WebDAVCertificateIssue(certificate: certificate, changed: changed, canTrust: validation.acceptable, requiresExplicitIPTrust: validation.explicitIPTrust)
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    var data = Data(), response: HTTPURLResponse?, error: Error?
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { error = WebDAVFailure.redirect; completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(SharedVault.maximumSize) { error = WebDAVFailure.tooLarge; completionHandler(.cancel) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        if data.count + chunk.count > SharedVault.maximumSize { error = WebDAVFailure.tooLarge; dataTask.cancel() }
        else { data.append(chunk) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError failure: Error?) { if error == nil, let failure {
            let value = failure as NSError
            error = value.domain == NSURLErrorDomain && (-1206 ... -1200).contains(value.code) ? WebDAVFailure.tls : WebDAVFailure.network
        }; done.signal() }
}
/// Accept only a successful DAV resourcetype for the requested collection.
private final class DAVCollectionResponse: NSObject, XMLParserDelegate {
    let target: URL
    var stack = [String](), text = "", href = "", status = ""
    var collection = false, validProperty = false, matches = 0, isCollection = false
    init(_ target: URL) { self.target = target }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(namespaceURI == "DAV:" ? element : "?"); text = ""
        if stack == ["multistatus", "response"] { href = ""; validProperty = false }
        if stack == ["multistatus", "response", "propstat"] { status = ""; collection = false }
        if stack == ["multistatus", "response", "propstat", "prop", "resourcetype", "collection"] { collection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if stack == ["multistatus", "response", "href"] { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if stack == ["multistatus", "response", "propstat", "status"] { status = text }
        if stack == ["multistatus", "response", "propstat"], status.split(separator: " ").dropFirst().first == "200", collection { validProperty = true }
        if stack == ["multistatus", "response"], !href.isEmpty, let url = URL(string: href, relativeTo: target)?.absoluteURL,
           url.scheme == target.scheme, url.host == target.host, url.port == target.port,
           url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == target.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            matches += 1; isCollection = validProperty
        }
        stack.removeLast(); text = ""
    }
    static func validate(_ data: Data, at url: URL) -> Bool {
        let delegate = DAVCollectionResponse(url), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        return parser.parse() && delegate.matches == 1 && delegate.isCollection
    }
}
public final class WebDAVClient {
    private let settings: WebDAVSettings, directory: URL
    private let lock = NSLock()
    private var active: URLSession?, cancelled = false
    private var resolvedDirectory: URL?
    public init(_ settings: WebDAVSettings, allowLoopbackHTTP: Bool = false) throws { self.settings = settings; directory = try settings.directory(allowLoopbackHTTP: allowLoopbackHTTP) }
    public func cancel() { lock.lock(); cancelled = true; let session = active; lock.unlock(); session?.invalidateAndCancel() }
    private func request(_ method: String, url: URL, data: Data? = nil, headers: [String: String] = [:]) throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = data
        request.setValue("Basic " + Data((settings.username + ":" + settings.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("OShell", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let delegate = DAVRequest(endpoint: directory, pinned: settings.trustedServerCertificate), queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        lock.lock(); let stopped = cancelled; if !stopped { active = session }; lock.unlock()
        defer { session.invalidateAndCancel(); lock.lock(); active = nil; lock.unlock() }
        guard !stopped else { throw WebDAVFailure.network }
        session.dataTask(with: request).resume()
        guard delegate.done.wait(timeout: .now() + 50) == .success else { session.invalidateAndCancel(); throw WebDAVFailure.network }
        if let error = delegate.error { throw error }
        guard let response = delegate.response else { throw WebDAVFailure.network }
        if [401, 403].contains(response.statusCode) { throw WebDAVFailure.authentication }
        if (300...399).contains(response.statusCode) { throw WebDAVFailure.redirect }
        return (response, delegate.data)
    }
    private func collectionExists(_ url: URL) throws -> Bool {
        let body = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let (response, data) = try request("PROPFIND", url: url, data: body, headers: ["Depth":"0", "Content-Type":"application/xml; charset=utf-8"])
        if response.statusCode == 404 { return false }
        guard response.statusCode == 207 else { throw WebDAVFailure.status(response.statusCode) }
        guard DAVCollectionResponse.validate(data, at: url) else { throw ModelError.invalid("WebDAV 的 oshell 位置不是可访问的目录，或服务器目录响应无效；未写入同步数据。") }
        return true
    }
    /// Keep old direct-file endpoints in place; new endpoints use an oshell child.
    public func syncDirectory() throws -> URL {
        if let resolvedDirectory { return resolvedDirectory }
        let explicit = directory.lastPathComponent.lowercased() == "oshell"
        if !explicit, try fetchObject(in: directory) != nil {
            resolvedDirectory = directory; return directory
        }
        let target = explicit ? directory : directory.appendingPathComponent("oshell", isDirectory: true)
        if try !collectionExists(target) {
            let (response, _) = try request("MKCOL", url: target)
            // Another device may create it between PROPFIND and MKCOL. Never
            // treat 405 alone as proof of a directory (it could be a file).
            guard [201, 405].contains(response.statusCode) else { throw WebDAVFailure.status(response.statusCode) }
            guard try collectionExists(target) else { throw WebDAVFailure.status(404) }
        }
        resolvedDirectory = target; return target
    }
    public func probe() throws { _ = try syncDirectory(); _ = try fetch() }
    public func fetch() throws -> WebDAVObject? { try fetchObject(in: syncDirectory()) }
    private func fetchObject(in directory: URL) throws -> WebDAVObject? {
        let (response, data) = try request("GET", url: directory.appendingPathComponent("oshell-vault.json"))
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw WebDAVFailure.status(response.statusCode) }
        guard let tag = response.allHeaderFields.first(where: { String(describing: $0.key).lowercased() == "etag" }).map({ String(describing: $0.value) }), Self.validETag(tag) else { throw WebDAVFailure.unsafeVersion }
        return WebDAVObject(data: data, etag: tag)
    }
    public static func validETag(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count >= 2 && bytes.count <= 1024 && bytes.first == 34 && bytes.last == 34 && bytes.dropFirst().dropLast().allSatisfy { $0 == 33 || $0 >= 35 && $0 != 127 }
    }
    public func put(_ data: Data, matching etag: String?) throws {
        guard data.count <= SharedVault.maximumSize else { throw WebDAVFailure.tooLarge }
        if let etag, !Self.validETag(etag) { throw WebDAVFailure.unsafeVersion }
        let headers = ["Content-Type":"application/json", etag == nil ? "If-None-Match" : "If-Match": etag ?? "*"]
        let (response, _) = try request("PUT", url: syncDirectory().appendingPathComponent("oshell-vault.json"), data: data, headers: headers)
        if response.statusCode == 412 { throw WebDAVFailure.conflict }
        guard [200, 201, 204].contains(response.statusCode) else { throw WebDAVFailure.status(response.statusCode) }
    }
}
