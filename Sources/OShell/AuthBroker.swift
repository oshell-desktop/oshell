// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

/// Run modal authentication outside a main-dispatch block, and never nest
/// authentication windows from different transports. Owned by the main thread.
private final class AuthenticationQueue {
    static let shared = AuthenticationQueue()
    private final class Entry {
        let owner: UUID
        let operation: (@escaping (AuthResponse) -> Void) -> Void
        let completion: (AuthResponse) -> Void
        var finished = false
        init(owner: UUID, operation: @escaping (@escaping (AuthResponse) -> Void) -> Void, completion: @escaping (AuthResponse) -> Void) {
            self.owner = owner; self.operation = operation; self.completion = completion
        }
        func finish(_ response: AuthResponse) {
            guard !finished else { return }; finished = true; completion(response)
        }
    }
    private var pending = [Entry](), active: Entry?, timer: Timer?
    func enqueue(owner: UUID, operation: @escaping (@escaping (AuthResponse) -> Void) -> Void, completion: @escaping (AuthResponse) -> Void) {
        pending.append(Entry(owner: owner, operation: operation, completion: completion)); schedule()
    }
    func cancel(owner: UUID) {
        let removed = pending.filter { $0.owner == owner }; pending.removeAll { $0.owner == owner }
        removed.forEach { $0.finish(AuthResponse(success: false)) }
        if let entry = active, entry.owner == owner { active = nil; entry.finish(AuthResponse(success: false)) }
        schedule()
    }
    private func schedule() {
        guard active == nil, !pending.isEmpty else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.drain() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
    }
    private func drain() {
        guard active == nil, NSApp.modalWindow == nil, !pending.isEmpty else { return }
        timer?.invalidate(); timer = nil
        let entry = pending.removeFirst(); active = entry
        entry.operation { [weak self, weak entry] response in
            guard let self, let entry else { return }
            entry.finish(response)
            if self.active === entry { self.active = nil }
            self.schedule()
        }
    }
}

final class AuthBroker {
    private let authenticationOwner = UUID()
    private weak var promptWindow: NSWindow?
    private let directory: URL
    private let endpoint: URL
    private let token = UUID().uuidString + UUID().uuidString
    private let queue = DispatchQueue(label: "OShell.auth.accept", qos: .userInitiated)
    private var source: DispatchSourceRead?
    private var stopped = false
    private var policy: SavedPasswordPolicy?
    private var proxyAttempted = false
    private var routeAttempts = Set<UUID>()
    private var routePolicies = [UUID: SavedPasswordPolicy]()
    private var pendingPassword: (String, SSHIdentity)?
    private let permitsSaving: Bool
    private lazy var loginIdentity: SSHIdentity? = try? SSHIdentity.resolve(profile)
    private let profile: SessionProfile
    var onAuthenticated: (() -> Void)?
    var onSavePassword: ((SessionProfile, String, SSHIdentity) -> Void)?
    var manualPrompt: ((AuthRequest, @escaping (AuthResponse) -> Void) -> Void)?
    init(profile: SessionProfile, oneTimePassword: String? = nil, permitsSaving: Bool = true) throws {
        guard profile.runtimeProxyRoute.count <= ProxyCatalog.maximumHops, Set(profile.runtimeProxyRoute.map(\.id)).count == profile.runtimeProxyRoute.count else { throw ModelError.invalid("代理链重复或过长。") }
        for proxy in profile.runtimeProxyRoute { try proxy.validate() }
        self.profile = profile; self.permitsSaving = permitsSaving && oneTimePassword == nil
        if let oneTimePassword { policy = SavedPasswordPolicy(identity: try SSHIdentity.resolve(profile), password: oneTimePassword) }
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oa-" + String(UUID().uuidString.prefix(8)))
        endpoint = directory.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ModelError.invalid("无法创建密码认证通道。") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = try AuthIPC.address(endpoint.path)
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw ModelError.invalid("无法绑定密码认证通道。") }
        _ = chmod(endpoint.path, 0o600)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC); _ = fcntl(client, F_SETFL, 0)
                var noSignal: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); continue }
                DispatchQueue.global(qos: .userInitiated).async {
                    var timeout = timeval(tv_sec: 5, tv_usec: 0)
                    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    do {
                        let request = try AuthIPC.read(AuthRequest.self, fd: client)
                        DispatchQueue.main.async {
                            guard let self, !self.stopped, request.token == self.token else { close(client); return }
                            self.enqueue(request, client: client) { [weak self] response in
                                let allowedResponse = self?.stopped == false ? response : AuthResponse(success: false)
                                DispatchQueue.global(qos: .userInitiated).async {
                                    try? AuthIPC.write(allowedResponse, fd: client)
                                    close(client)
                                }
                            }
                        }
                    } catch { close(client) }
                }
            }
        }
        reader.setCancelHandler { close(fd) }; reader.resume(); source = reader
    }
    var environment: [String: String] {
        var values = ["SSH_ASKPASS": ZmodemTransfer.helperDirectory.appendingPathComponent("OShellAskpass").path,
                      "SSH_ASKPASS_REQUIRE": "force", "OSHELL_AUTH_PROXY_ID": "", "OSHELL_AUTH_SOCKET": endpoint.path, "OSHELL_AUTH_TOKEN": token]
        if OpenSSHCapabilities.current.needsLegacyAskpass {
            values.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
            values["DISPLAY"] = ProcessInfo.processInfo.environment["DISPLAY"] ?? "oshell:0"
        }
        return values
    }
    private func enqueue(_ request: AuthRequest, client: Int32, completion: @escaping (AuthResponse) -> Void) {
        // These are protocol notifications, never prompts. In particular a ready
        // notification must not wait behind another connection's password dialog.
        if ["oshell-proxy-route", "oshell-session-ready", "none"].contains(request.hint), request.proxyID == nil {
            respond(request, completion: completion); return
        }
        AuthenticationQueue.shared.enqueue(owner: authenticationOwner, operation: { [weak self] done in
            guard let self, !self.stopped else { done(AuthResponse(success: false)); return }
            var byte: UInt8 = 0
            let count = recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { done(AuthResponse(success: false)); return }
            self.respond(request, completion: done)
        }, completion: completion)
    }
    private func runPrompt(_ alert: PopupAlert) -> NSApplication.ModalResponse {
        promptWindow = alert.window
        defer { promptWindow = nil }
        return alert.runModal()
    }
    private func respond(_ request: AuthRequest, completion: @escaping (AuthResponse) -> Void) {
        if request.hint == "oshell-proxy-route" {
            var route = profile.runtimeProxyRoute
            for index in route.indices { route[index].encryptedPassword = nil }
            let encoded = (try? JSONEncoder().encode(route)).flatMap { String(data: $0, encoding: .utf8) }
            completion(AuthResponse(success: encoded != nil && !route.isEmpty, answer: encoded ?? "")); return
        }
        if let id = request.proxyID {
            guard let proxy = profile.runtimeProxyRoute.first(where: { $0.id == id }) else { completion(AuthResponse(success: false)); return }
            respondProxy(proxy, request: request, completion: completion); return
        }
        if request.hint == "oshell-session-ready" {
            let pending = pendingPassword; pendingPassword = nil
            onAuthenticated?(); completion(AuthResponse(success: true))
            if let pending {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.onSavePassword?(self.profile, pending.0, pending.1)
                }
            }
            return
        }
        if request.hint == "oshell-proxy" {
            guard profile.proxy.supportsPassword, !profile.proxy.username.isEmpty, !proxyAttempted else { completion(AuthResponse(success: false)); return }
            proxyAttempted = true
            if profile.proxy.encryptedPassword != nil {
                PasswordVault.shared.decrypt(profile.proxy.credentialProfile, resolve: false) { [weak self] result in
                    guard let self, !self.stopped else { completion(AuthResponse(success: false)); return }
                    switch result {
                    case .success(let value): completion(AuthResponse(success: true, answer: value.0))
                    case .failure(let error): Dialogs.message(error.localizedDescription); completion(AuthResponse(success: false))
                    }
                }
            } else if let manualPrompt { manualPrompt(request, completion) }
            else {
                let alert = PopupAlert(); alert.messageText = "代理身份验证"; alert.informativeText = "\(profile.proxy.username)@\(profile.proxy.host):\(profile.proxy.port)"
                alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
                let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 26))
                alert.accessoryView = password; alert.window.initialFirstResponder = password
                let accepted = runPrompt(alert) == .alertFirstButtonReturn
                completion(AuthResponse(success: accepted, answer: accepted ? password.stringValue : "")); password.stringValue = ""
            }
            return
        }
        if request.hint == "none" { completion(AuthResponse(success: true)); return }
        let saveIdentity: SSHIdentity? = {
            guard permitsSaving, profile.kind == .ssh, onSavePassword != nil, let identity = loginIdentity else { return nil }
            var match = SavedPasswordPolicy(identity: identity, password: "probe")
            return match.reply(prompt: request.prompt, hint: request.hint) == nil ? nil : identity
        }()
        // A repeated password prompt means the preceding attempt was rejected.
        if saveIdentity != nil { pendingPassword = nil }
        if var policy, let answer = policy.reply(prompt: request.prompt, hint: request.hint) {
            self.policy = policy; completion(AuthResponse(success: true, answer: answer)); return
        }
        if policy == nil, let envelope = profile.encryptedPassword, request.hint != "confirm" {
            var check = SavedPasswordPolicy(identity: envelope.identity, password: "probe")
            if check.reply(prompt: request.prompt, hint: request.hint) != nil {
                PasswordVault.shared.decrypt(profile) { [weak self] result in
                    guard let self, !self.stopped else { completion(AuthResponse(success: false)); return }
                    switch result {
                    case .success(let value):
                        var policy = SavedPasswordPolicy(identity: value.1, password: value.0)
                        let answer = policy.reply(prompt: request.prompt, hint: request.hint)
                        self.policy = policy; completion(AuthResponse(success: answer != nil, answer: answer ?? ""))
                    case .failure(let error): Dialogs.message(error.localizedDescription); completion(AuthResponse(success: false))
                    }
                }
                return
            }
        }
        if let manualPrompt { manualPrompt(request, completion); return }
        let alert = PopupAlert(); alert.messageText = "SSH 身份验证"; alert.informativeText = profile.name + "\n" + request.prompt
        if request.hint == "confirm" || request.prompt.contains("(yes/no") {
            alert.addButton(withTitle: "确认连接"); alert.addButton(withTitle: "取消")
            completion(AuthResponse(success: true, answer: runPrompt(alert) == .alertFirstButtonReturn ? "yes" : "no")); return
        }
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let field = PasswordEntryView(identifier: "ssh.auth.password")
        let save = NSButton(checkboxWithTitle: "连接成功后保存密码到会话配置", target: nil, action: nil)
        save.identifier = .init("ssh.auth.savePassword"); save.state = .off
        save.isEnabled = saveIdentity != nil
        save.toolTip = saveIdentity == nil ? "仅保存当前目标的 SSH 登录密码；密钥口令、验证码及一次性凭据不保存。" : "使用 OShell 当前的主密码或本机密钥加密保存，下次连接时使用。"
        var controls: [NSView] = [field]
        if let identity = saveIdentity {
            let account = NSTextField(labelWithString: "账号：\(identity.user)    主机：\(identity.host):\(identity.port)")
            account.lineBreakMode = .byTruncatingMiddle; controls.insert(account, at: 0)
        }
        if onSavePassword != nil { controls.append(save) }
        let content = NSStackView(views: controls); content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.frame = NSRect(x: 0, y: 0, width: 440, height: CGFloat(controls.count) * 30)
        field.widthAnchor.constraint(equalToConstant: 440).isActive = true
        alert.accessoryView = content; alert.window.initialFirstResponder = field.secureField
        let accepted = runPrompt(alert) == .alertFirstButtonReturn && !stopped
        let answer = accepted ? field.stringValue : ""; field.clear()
        if accepted, save.state == .on, let identity = saveIdentity, !answer.isEmpty { pendingPassword = (answer, identity) }
        else if !accepted { pendingPassword = nil }
        completion(AuthResponse(success: accepted, answer: answer))
    }

    private func respondProxy(_ proxy: ProxySettings, request: AuthRequest, completion: @escaping (AuthResponse) -> Void) {
        let credential = proxy.credentialProfile
        if proxy.kind != .jump {
            guard request.hint == "oshell-proxy", proxy.supportsPassword, !routeAttempts.contains(proxy.id) else { completion(AuthResponse(success: false)); return }
            routeAttempts.insert(proxy.id)
            if credential.encryptedPassword != nil {
                PasswordVault.shared.decrypt(credential, resolve: false) { [weak self] result in
                    guard let self, !self.stopped else { completion(AuthResponse(success: false)); return }
                    switch result { case .success(let value): completion(AuthResponse(success: true, answer: value.0))
                    case .failure(let error): Dialogs.message(error.localizedDescription); completion(AuthResponse(success: false)) }
                }; return
            }
        } else if request.hint != "confirm" {
            if var saved = routePolicies[proxy.id], let answer = saved.reply(prompt: request.prompt, hint: request.hint) {
                routePolicies[proxy.id] = saved; completion(AuthResponse(success: true, answer: answer)); return
            }
            if routePolicies[proxy.id] == nil, let envelope = credential.encryptedPassword {
                var probe = SavedPasswordPolicy(identity: envelope.identity, password: "probe")
                if probe.reply(prompt: request.prompt, hint: request.hint) != nil {
                    PasswordVault.shared.decrypt(credential) { [weak self] result in
                        guard let self, !self.stopped else { completion(AuthResponse(success: false)); return }
                        switch result {
                        case .success(let value):
                            var policy = SavedPasswordPolicy(identity: value.1, password: value.0)
                            let answer = policy.reply(prompt: request.prompt, hint: request.hint); self.routePolicies[proxy.id] = policy
                            completion(AuthResponse(success: answer != nil, answer: answer ?? ""))
                        case .failure(let error): Dialogs.message(error.localizedDescription); completion(AuthResponse(success: false))
                        }
                    }; return
                }
            }
        }
        if let manualPrompt { manualPrompt(request, completion); return }
        let alert = PopupAlert(); alert.messageText = proxy.kind == .jump ? "SSH 跳板机认证" : "代理身份验证"
        alert.informativeText = "\(proxy.username)@\(proxy.host):\(proxy.port)\n" + (proxy.kind == .jump ? request.prompt : "请输入代理密码。")
        if request.hint == "confirm" || request.prompt.contains("(yes/no") {
            alert.addButton(withTitle: "确认连接"); alert.addButton(withTitle: "取消")
            completion(AuthResponse(success: true, answer: runPrompt(alert) == .alertFirstButtonReturn ? "yes" : "no")); return
        }
        alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        let accepted = runPrompt(alert) == .alertFirstButtonReturn && !stopped
        completion(AuthResponse(success: accepted, answer: accepted ? field.stringValue : "")); field.stringValue = ""
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let promptWindow, NSApp.modalWindow === promptWindow { _ = PopupKeyboard.dismiss(window: promptWindow) }
        AuthenticationQueue.shared.cancel(owner: authenticationOwner); routePolicies = [:]; routeAttempts = []; policy = nil; pendingPassword = nil; source?.cancel(); source = nil; try? FileManager.default.removeItem(at: directory) }
    deinit { AuthenticationQueue.shared.cancel(owner: authenticationOwner); source?.cancel(); try? FileManager.default.removeItem(at: directory) }
}
