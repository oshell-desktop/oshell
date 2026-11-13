// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import Security

public struct WebDAVSettings: Codable {
    public enum Authentication: String, Codable { case basic, digest }
    public var address: String
    public var username: String
    public var password: String
    public var authentication: Authentication = .basic
    /// Stored only in this Mac's encrypted WebDAV settings, not the shared vault configuration.
    public var trustedServerCertificate: WebDAVCertificateTrust? = nil
    public init(address: String, username: String, password: String) { self.address = address; self.username = username; self.password = password }
    private enum CodingKeys: String, CodingKey { case address, username, password, authentication, trustedServerCertificate }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        address = try values.decode(String.self, forKey: .address)
        username = try values.decode(String.self, forKey: .username)
        password = try values.decode(String.self, forKey: .password)
        authentication = try values.decodeIfPresent(Authentication.self, forKey: .authentication) ?? .basic
        trustedServerCertificate = try values.decodeIfPresent(WebDAVCertificateTrust.self, forKey: .trustedServerCertificate)
    }
    // Keep the argument for source compatibility with existing interop helpers.
    public func directory(allowLoopbackHTTP: Bool = false) throws -> URL {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              username.utf8.count <= 4096, password.utf8.count <= 4096, !username.contains("\0"), !password.contains("\0"),
              !username.contains(":"), !username.contains("\n"), !username.contains("\r"), !password.contains("\n"), !password.contains("\r") else {
            throw ModelError.invalid("请输入 HTTP 或 HTTPS WebDAV 目录地址，使用有效端口，并将账号密码填写在单独字段中（最多 4096 字节，不含换行或空字符）。")
        }
        parts.scheme = parts.scheme?.lowercased()
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw ModelError.invalid("WebDAV 地址无效。") }; return url
    }
}
public struct WebDAVObject: Equatable {
    public let data: Data
    fileprivate let version: String?
    fileprivate let nutstoreTag: String?
    init(data: Data, etag: String?, nutstoreTag: String? = nil) {
        self.data = data; version = etag; self.nutstoreTag = nutstoreTag
    }

    public var etag: String {
        get throws {
            guard let version else { throw WebDAVFailure.unsafeVersion }
            return version
        }
    }
}
public enum WebDAVFailure: Error, LocalizedError {
    case conflict, occupied, uncertainWrite, authentication, status(Int), unsafeVersion, network, tls, tooLarge, redirect
    public var errorDescription: String? {
        switch self {
        case .conflict: return "共享版本已变化，未覆盖。请重新同步并确认冲突。"
        case .occupied: return "另一台设备占用了坚果云写入标记。请稍后重新同步。"
        case .uncertainWrite: return "坚果云写入或释放标记的结果不确定。请核对远端文件和写入标记后再同步。"
        case .authentication: return "WebDAV 身份验证失败，请检查认证方式、账号、密码及服务器支持的认证算法。"
        case .status(let code): return "WebDAV 返回 HTTP \(code)。请确认目录存在且账号有读写权限。"
        case .unsafeVersion: return "服务器未提供用于更新此文件的强 ETag。已停止覆盖该文件，本地修改已保留。"
        case .tls: return "WebDAV TLS 连接或证书校验失败，请检查服务器证书和 HTTPS 配置。"
        case .network: return "WebDAV 网络请求失败或超时，本地数据已保留。"
        case .tooLarge: return "WebDAV 响应超过大小限制。"
        case .redirect: return "WebDAV 地址发生重定向。请直接填写最终 HTTP / HTTPS 目录地址。"
        }
    }
}
private final class DAVRequest: NSObject, URLSessionDataDelegate {
    let done = DispatchSemaphore(value: 0)
    let endpoint: URL
    let pinned: WebDAVCertificateTrust?
    let settings: WebDAVSettings
    var authenticationResponse: HTTPURLResponse?
    init(endpoint: URL, settings: WebDAVSettings) { self.endpoint = endpoint; self.settings = settings; pinned = settings.trustedServerCertificate }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            urlSession(session, didReceive: challenge, completionHandler: completionHandler); return
        }
        guard settings.authentication == .digest,
              !space.isProxy(), space.protocol == endpoint.scheme,
              WebDAVCertificateTrust.normalizedHost(space.host) == endpoint.host.map(WebDAVCertificateTrust.normalizedHost),
              space.port == (endpoint.port ?? 443),
              let response = challenge.failureResponse as? HTTPURLResponse, response.statusCode == 401 else {
            error = WebDAVFailure.authentication; completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        authenticationResponse = response
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
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
private final class DAVPropertyResponse: NSObject, XMLParserDelegate {
    let target: URL
    var stack = [String](), text = "", href = "", status = ""
    var collection = false, validProperty = false, matches = 0, isCollection = false
    var propertyTag: String?, responseTag: String?, etag: String?
    init(_ target: URL) { self.target = target }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(namespaceURI == "DAV:" ? element : "?"); text = ""
        if stack == ["multistatus", "response"] { href = ""; validProperty = false; responseTag = nil }
        if stack == ["multistatus", "response", "propstat"] { status = ""; collection = false; propertyTag = nil }
        if stack == ["multistatus", "response", "propstat", "prop", "resourcetype", "collection"] { collection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if stack == ["multistatus", "response", "href"] { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if stack == ["multistatus", "response", "propstat", "status"] { status = text }
        if stack == ["multistatus", "response", "propstat", "prop", "getetag"] {
            propertyTag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if stack == ["multistatus", "response", "propstat"], status.split(separator: " ").dropFirst().first == "200" {
            if collection { validProperty = true }
            if let propertyTag { responseTag = propertyTag }
        }
        if stack == ["multistatus", "response"], !href.isEmpty, let url = URL(string: href, relativeTo: target)?.absoluteURL,
           url.scheme == target.scheme, url.host == target.host, url.port == target.port,
           url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == target.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            matches += 1; isCollection = validProperty; etag = responseTag
        }
        stack.removeLast(); text = ""
    }
    static func parse(_ data: Data, at url: URL) -> DAVPropertyResponse? {
        let delegate = DAVPropertyResponse(url), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        return parser.parse() && delegate.matches == 1 ? delegate : nil
    }
}
public final class WebDAVClient: FontSyncTransport {
    private let settings: WebDAVSettings, directory: URL
    private let lock = NSLock()
    private var active: URLSession?, cancelled = false
    private var activeHTTP: WebDAVHTTPRequest?
    private let nutstore: Bool
    private var resolvedDirectory: URL?
    public init(_ settings: WebDAVSettings, allowLoopbackHTTP: Bool = false) throws {
        self.settings = settings; directory = try settings.directory(allowLoopbackHTTP: allowLoopbackHTTP)
        nutstore = directory.scheme == "https" && directory.host?.lowercased() == "dav.jianguoyun.com" && (directory.port ?? 443) == 443
    }
    @_spi(Testing) public init(nutstoreFixture settings: WebDAVSettings) throws {
        self.settings = settings; directory = try settings.directory()
        guard directory.scheme == "http", directory.host == "127.0.0.1" else { throw WebDAVFailure.network }
        nutstore = true
    }
    public func cancel() { lock.lock(); cancelled = true; let session = active, http = activeHTTP; lock.unlock(); session?.invalidateAndCancel(); http?.cancel() }
    private func request(_ method: String, url: URL, data: Data? = nil, headers: [String: String] = [:]) throws -> (HTTPURLResponse, Data) {
        if url.scheme == "http" {
            let task = WebDAVHTTPRequest()
            lock.lock(); let stopped = cancelled; if !stopped { activeHTTP = task }; lock.unlock()
            defer { lock.lock(); activeHTTP = nil; lock.unlock() }
            guard !stopped else { throw WebDAVFailure.network }
            var fields = headers
            if settings.authentication == .basic { fields["Authorization"] = "Basic " + Data((settings.username + ":" + settings.password).utf8).base64EncodedString() }
            fields["User-Agent"] = "OShell"
            let result = try task.perform(method, url: url, body: data, headers: fields, settings: settings)
            if [401, 403].contains(result.0.statusCode) { throw WebDAVFailure.authentication }
            if (300...399).contains(result.0.statusCode) { throw WebDAVFailure.redirect }
            return result
        }
        var authorization: String?, previousNonce: String?
        for attempt in 0..<3 {
            let result = try requestHTTPS(method, url: url, data: data, headers: headers, authorization: authorization)
            if result.0.statusCode != 401 {
                if result.0.statusCode == 403 { throw WebDAVFailure.authentication }
                if (300...399).contains(result.0.statusCode) { throw WebDAVFailure.redirect }
                return result
            }
            guard settings.authentication == .digest, attempt < 2,
                  let challenge = result.0.value(forHTTPHeaderField: "WWW-Authenticate") else { throw WebDAVFailure.authentication }
            let digest = try WebDAVDigest(header: challenge)
            guard previousNonce == nil || (digest.stale && digest.nonce != previousNonce) else { throw WebDAVFailure.authentication }
            authorization = try digest.authorization(method: method, url: url, username: settings.username, password: settings.password)
            previousNonce = digest.nonce
        }
        throw WebDAVFailure.authentication
    }
    private func requestHTTPS(_ method: String, url: URL, data: Data?, headers: [String: String], authorization: String?) throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = data
        if settings.authentication == .basic { request.setValue("Basic " + Data((settings.username + ":" + settings.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        else if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.setValue("OShell", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let delegate = DAVRequest(endpoint: directory, settings: settings), queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        lock.lock(); let stopped = cancelled; if !stopped { active = session }; lock.unlock()
        defer { session.invalidateAndCancel(); lock.lock(); active = nil; lock.unlock() }
        guard !stopped else { throw WebDAVFailure.network }
        session.dataTask(with: request).resume()
        guard delegate.done.wait(timeout: .now() + 50) == .success else { session.invalidateAndCancel(); throw WebDAVFailure.network }
        if let response = delegate.authenticationResponse { return (response, Data()) }
        if let error = delegate.error { throw error }
        guard let response = delegate.response else { throw WebDAVFailure.network }
        return (response, delegate.data)
    }
    private func collectionExists(_ url: URL) throws -> Bool {
        let body = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let (response, data) = try request("PROPFIND", url: url, data: body, headers: ["Depth":"0", "Content-Type":"application/xml; charset=utf-8"])
        if response.statusCode == 404 { return false }
        guard response.statusCode == 207 else { throw WebDAVFailure.status(response.statusCode) }
        guard DAVPropertyResponse.parse(data, at: url)?.isCollection == true else { throw ModelError.invalid("WebDAV 的 oshell 位置不是可访问的目录，或服务器目录响应无效；未写入同步数据。") }
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
    public enum ProbeResult { case empty, versioned, coordinated, readOnly }
    @discardableResult public func probe() throws -> ProbeResult {
        let url = try syncDirectory().appendingPathComponent("oshell-vault.json")
        guard let object = try read(url) else { return .empty }
        if nutstore { return object.nutstoreTag == nil ? .readOnly : .coordinated }
        do { _ = try replacementTag(object, at: url); return .versioned }
        catch WebDAVFailure.unsafeVersion { return .readOnly }
    }
    public func fetch() throws -> WebDAVObject? { try fetchObject(in: syncDirectory()) }
    private func fetchObject(in directory: URL) throws -> WebDAVObject? {
        try read(directory.appendingPathComponent("oshell-vault.json"))
    }
    private func read(_ url: URL, matching tag: String? = nil) throws -> WebDAVObject? {
        var headers = ["Accept-Encoding": "identity"]
        if let tag { headers["If-Match"] = tag }
        let (response, data) = try request("GET", url: url, headers: headers)
        if response.statusCode == 404 { return nil }
        if response.statusCode == 412 { throw WebDAVFailure.conflict }
        guard response.statusCode == 200 else { throw WebDAVFailure.status(response.statusCode) }
        if nutstore {
            let tag = response.value(forHTTPHeaderField: "ETag").flatMap { raw -> String? in
                guard !raw.isEmpty, raw.utf8.count <= 1024, !raw.hasPrefix("W/"), raw != "*",
                      Self.validETag(raw) || raw.utf8.allSatisfy({ (33...126).contains($0) && $0 != 34 && $0 != 44 && $0 != 42 }) else { return nil }
                return raw
            }
            // The local digest identifies the merge snapshot. Only the server's own tag goes into If-Match.
            let revision = tag.map { _ in PlatformDigest.sha256(data).map { String(format: "%02x", $0) }.joined() }
            return WebDAVObject(data: data, etag: revision, nutstoreTag: tag)
        }
        let version = response.value(forHTTPHeaderField: "ETag").flatMap { Self.validETag($0) ? $0 : nil }
        return WebDAVObject(data: data, etag: version)
    }

    private func replacementTag(_ object: WebDAVObject?, at url: URL) throws -> String? {
        guard let object else { return nil }
        if let version = object.version { return version }
        let body = Data("<d:propfind xmlns:d=\"DAV:\"><d:prop><d:getetag/></d:prop></d:propfind>".utf8)
        let (response, data) = try request("PROPFIND", url: url, data: body, headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"])
        if response.statusCode == 404 { throw WebDAVFailure.conflict }
        if [405, 501].contains(response.statusCode) { throw WebDAVFailure.unsafeVersion }
        guard response.statusCode == 207 else { throw WebDAVFailure.status(response.statusCode) }
        guard let tag = DAVPropertyResponse.parse(data, at: url)?.etag, Self.validETag(tag) else { throw WebDAVFailure.unsafeVersion }
        // PROPFIND can observe a newer revision than the GET used for merging.
        guard let verified = try read(url, matching: tag), verified.data == object.data,
              verified.version == nil || verified.version == tag else { throw WebDAVFailure.conflict }
        return tag
    }
    public func put(_ data: Data, replacing object: WebDAVObject?) throws {
        if nutstore { try put(data, matching: object?.etag); return }
        let url = try syncDirectory().appendingPathComponent("oshell-vault.json")
        try put(data, matching: replacementTag(object, at: url))
    }
    public static func validETag(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count >= 2 && bytes.count <= 1024 && bytes.first == 34 && bytes.last == 34 && bytes.dropFirst().dropLast().allSatisfy { $0 == 33 || $0 >= 35 && $0 != 127 }
    }
    public func put(_ data: Data, matching etag: String?) throws {
        guard data.count <= SharedVault.maximumSize else { throw WebDAVFailure.tooLarge }
        if nutstore {
            try nutstoreWrite(data, at: syncDirectory().appendingPathComponent("oshell-vault.json"), expected: etag, type: "application/json")
            return
        }
        if let etag, !Self.validETag(etag) { throw WebDAVFailure.unsafeVersion }
        let headers = ["Content-Type":"application/json", etag == nil ? "If-None-Match" : "If-Match": etag ?? "*"]
        let (response, _) = try request("PUT", url: syncDirectory().appendingPathComponent("oshell-vault.json"), data: data, headers: headers)
        if response.statusCode == 412 { throw WebDAVFailure.conflict }
        guard [200, 201, 204].contains(response.statusCode) else { throw WebDAVFailure.status(response.statusCode) }
    }
    public func checkFontSyncActive() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { throw ModelError.invalid("字体同步已取消。") }
    }
    private func fontURL(_ name: String, create: Bool) throws -> URL {
        guard FontLibrary.validAttachmentName(name) else { throw ModelError.invalid("字体附件路径无效。") }
        let folder = try syncDirectory().appendingPathComponent("fonts", isDirectory: true)
        if create, try !collectionExists(folder) {
            let (response, _) = try request("MKCOL", url: folder)
            guard [201, 405].contains(response.statusCode), try collectionExists(folder) else { throw WebDAVFailure.status(response.statusCode) }
        }
        return folder.appendingPathComponent(name)
    }
    public func fetchFont(_ name: String) throws -> WebDAVObject? {
        try read(fontURL(name, create: false))
    }
    public func putFont(_ data: Data, name: String, replacing object: WebDAVObject?) throws {
        if nutstore { try putFont(data, name: name, matching: object?.etag); return }
        let url = try fontURL(name, create: false)
        try putFont(data, name: name, matching: replacementTag(object, at: url))
    }
    public func putFont(_ data: Data, name: String, matching etag: String?) throws {
        guard data.count <= FontLibrary.maximumFileSize else { throw WebDAVFailure.tooLarge }
        if nutstore {
            try nutstoreWrite(data, at: fontURL(name, create: true), expected: etag, type: name == "library.json" ? "application/json" : "application/octet-stream")
            return
        }
        if let etag, !Self.validETag(etag) { throw WebDAVFailure.unsafeVersion }
        let headers = ["Content-Type": name == "library.json" ? "application/json" : "application/octet-stream", etag == nil ? "If-None-Match" : "If-Match": etag ?? "*"]
        let (response, _) = try request("PUT", url: fontURL(name, create: true), data: data, headers: headers)
        if response.statusCode == 412 { throw WebDAVFailure.conflict }
        guard [200, 201, 204].contains(response.statusCode) else { throw WebDAVFailure.status(response.statusCode) }
    }

    // Nutstore ignores create-only PUT and concurrent bare If-Match writes can both succeed.
    // MOVE with Overwrite:F publishes exactly one staged file at a previously absent name.
    private func publishNew(_ data: Data, at url: URL, type: String) throws {
        let stage = url.deletingLastPathComponent().appendingPathComponent("oshell-stage-" + UUID().uuidString + ".tmp")
        let (put, _) = try request("PUT", url: stage, data: data, headers: ["Content-Type": type, "If-None-Match": "*"])
        guard put.statusCode == 201 else { throw WebDAVFailure.status(put.statusCode) }
        let (move, _) = try request("MOVE", url: stage, headers: ["Destination": url.absoluteString, "Overwrite": "F"])
        if move.statusCode == 201 { return }
        _ = try? request("DELETE", url: stage)
        if [409, 412, 423].contains(move.statusCode) { throw WebDAVFailure.conflict }
        throw WebDAVFailure.status(move.statusCode)
    }

    private func nutstoreWrite(_ data: Data, at url: URL, expected: String?, type: String) throws {
        guard let expected else { try publishNew(data, at: url, type: type); return }
        let marker = url.appendingPathExtension("oshell-lock")
        do { try publishNew(Data(UUID().uuidString.utf8), at: marker, type: "text/plain") }
        catch WebDAVFailure.conflict { throw WebDAVFailure.occupied }

        var uncertain = false
        do {
            guard let current = try read(url), current.version == expected else { throw WebDAVFailure.conflict }
            guard let tag = current.nutstoreTag else { throw WebDAVFailure.unsafeVersion }
            uncertain = true
            let (response, _) = try request("PUT", url: url, data: data, headers: ["If-Match": tag, "Content-Type": type])
            if response.statusCode >= 500 { throw WebDAVFailure.uncertainWrite }
            uncertain = false
            if [404, 409, 412, 423].contains(response.statusCode) { throw WebDAVFailure.conflict }
            guard [200, 204].contains(response.statusCode) else { throw WebDAVFailure.status(response.statusCode) }
        } catch {
            // A timed-out PUT can still be executing remotely. Do not let a second writer overtake it.
            if uncertain { throw WebDAVFailure.uncertainWrite }
            try releaseNutstoreMarker(marker)
            throw error
        }
        try releaseNutstoreMarker(marker)
    }

    private func releaseNutstoreMarker(_ url: URL) throws {
        guard let (response, _) = try? request("DELETE", url: url), [200, 204].contains(response.statusCode) else {
            throw WebDAVFailure.uncertainWrite
        }
    }

}
