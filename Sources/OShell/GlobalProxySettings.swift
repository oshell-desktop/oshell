// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Local policy only. Proxy definitions and credentials stay in shared-vault v2.
struct GlobalProxySettings: Codable, Equatable {
    var version = 1
    var enabled = false
    var proxyID: UUID?
    static let didChange = Notification.Name("OShellGlobalProxyChanged")
    static var url: URL { StorageLocation.localStateDirectory.appendingPathComponent("global-proxy.json") }
    static func load() throws -> Self {
        guard let data = try SharedDataFile.readIfPresent(url) else { return .init() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw ModelError.invalid("全局代理设置版本不受支持，未建立连接。") }
        return value
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(self), to: Self.url)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    func resolve(_ source: SessionProfile, configuration: Configuration) throws -> SessionProfile {
        guard source.kind.usesSSH else { return source }
        guard enabled else { return try configuration.resolvingProxy(source) }
        guard let proxyID else { throw ModelError.invalid("全局代理已开启但未选择代理，未建立直连。请打开全局代理设置。") }
        let route = try ProxyCatalog.route(proxyID, in: configuration.proxies)
        for hop in route {
            guard hop.settings.kind != .none else { throw ModelError.invalid("全局代理配置无效，未建立直连。") }
            try hop.settings.validate()
        }
        var result = source
        // Preserve original session fields so disabling the policy restores them.
        result.runtimeProxyRoute = route.map(\.settings)
        return result
    }
}

extension WorkspaceController {
    func resolvedConnectionProfile(_ profile: SessionProfile) throws -> SessionProfile {
        guard profile.kind.usesSSH else { return profile }
        return try GlobalProxySettings.load().resolve(profile, configuration: configuration)
    }
    func configureGlobalProxyButton() {
        globalProxyButton.bezelStyle = .texturedRounded; globalProxyButton.setButtonType(.toggle)
        globalProxyButton.image = NSImage(systemSymbolName: "network", accessibilityDescription: "全局代理")
        globalProxyButton.imagePosition = .imageOnly
        globalProxyButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        globalProxyButton.identifier = .init("toolbar.globalProxy")
        globalProxyButton.target = self; globalProxyButton.action = #selector(toggleGlobalProxy)
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "全局代理设置…", action: #selector(showGlobalProxySettings), keyEquivalent: ""); settings.target = self
        globalProxyButton.menu = menu
        refreshGlobalProxyButton()
    }
    func refreshGlobalProxyButton() {
        globalProxyButton.isEnabled = isSecurityUnlocked
        do {
            let value = try GlobalProxySettings.load()
            let proxy = configuration.proxies.first { $0.id == value.proxyID }
            let validation = GlobalProxySettings(enabled: true, proxyID: value.proxyID)
            let valid = proxy != nil && (try? validation.resolve(SessionProfile.localForProxyValidation, configuration: configuration)) != nil
            globalProxyButton.state = value.enabled ? .on : .off
            globalProxyButton.contentTintColor = value.enabled ? (valid ? .systemBlue : .systemOrange) : .secondaryLabelColor
            let state = value.enabled ? (valid ? "已开启 · " + proxy!.name : "配置失效，连接将被阻止") : (valid ? "已关闭 · " + proxy!.name : "未配置")
            globalProxyButton.setAccessibilityLabel("全局代理：" + state)
            globalProxyButton.toolTip = "全局代理：" + state + "\n点击开关；右键或 Option 点击设置。仅新连接生效，已有连接及复用通道需重连才能切换。"
        } catch {
            globalProxyButton.contentTintColor = .systemOrange
            globalProxyButton.setAccessibilityLabel("全局代理设置无法读取")
            globalProxyButton.toolTip = error.localizedDescription
        }
    }
    @objc func toggleGlobalProxy() {
        guard isSecurityUnlocked else { return }
        defer { refreshGlobalProxyButton() }
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { showGlobalProxySettings(); return }
        do {
            var value = try GlobalProxySettings.load()
            if value.enabled { value.enabled = false; try value.save() }
            else if let id = value.proxyID, (try? ProxyCatalog.route(id, in: configuration.proxies)) != nil {
                value.enabled = true; _ = try value.resolve(SessionProfile.localForProxyValidation, configuration: configuration); try value.save()
            } else { showGlobalProxySettings() }
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc func showGlobalProxySettings() {
        guard isSecurityUnlocked else { return }
        do {
            var value = try GlobalProxySettings.load()
            while true {
                let catalog = configuration.proxies
                let alert = PopupAlert(); alert.messageText = "全局代理"
                alert.informativeText = "开启后，OShell 新建的 SSH、SFTP 及 SCP 连接统一使用所选代理或代理链，覆盖会话原有代理/跳板设置；关闭后恢复各会话设置。\n已有连接及其复用通道保持原路线，需重连才能切换。不会修改系统代理，也不接管本地 Shell 中手动运行的命令。\n代理条目与凭据沿用共享配置；此开关和选择仅本机保存。代理失败不会回退直连。"
                let apply = alert.addButton(withTitle: "应用"); apply.identifier = .init("globalProxy.apply")
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "新增 / 管理代理…").identifier = .init("globalProxy.manage")
                let enabled = NSButton(checkboxWithTitle: "开启全局代理", target: nil, action: nil)
                enabled.state = value.enabled ? .on : .off; enabled.identifier = .init("globalProxy.enabled")
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 28))
                picker.identifier = .init("globalProxy.selection")
                picker.addItems(withTitles: catalog.map { $0.name + " · " + $0.settings.kind.title + " · " + $0.settings.host + ":\($0.settings.port)" })
                if let index = catalog.firstIndex(where: { $0.id == value.proxyID }) { picker.selectItem(at: index) }
                if catalog.isEmpty { picker.addItem(withTitle: "请先新增代理"); picker.isEnabled = false }
                apply.isEnabled = true
                let help = NSTextField(wrappingLabelWithString: "支持 SOCKS4、SOCKS4A、SOCKS5、HTTP CONNECT 和 SSH 跳板机。推荐 SOCKS5；HTTP CONNECT 需要代理允许目标 SSH 端口。HTTPS 代理端点、PAC 与系统代理自动发现暂不支持。")
                help.font = .systemFont(ofSize: 12)
                let root = NSStackView(views: [enabled, picker, help]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
                root.frame = NSRect(x: 0, y: 0, width: 560, height: 130)
                help.widthAnchor.constraint(equalToConstant: 560).isActive = true
                alert.accessoryView = root
                let choice = alert.runModal()
                guard choice != .alertSecondButtonReturn else { return }
                value.enabled = enabled.state == .on
                value.proxyID = catalog.indices.contains(picker.indexOfSelectedItem) ? catalog[picker.indexOfSelectedItem].id : nil
                if choice == .alertThirdButtonReturn { showProxyManager(); NotificationCenter.default.post(name: GlobalProxySettings.didChange, object: nil); continue }
                guard choice == .alertFirstButtonReturn else { return }
                if value.enabled { _ = try value.resolve(SessionProfile.localForProxyValidation, configuration: configuration) }
                try value.save(); refreshGlobalProxyButton(); return
            }
        } catch { Dialogs.message(error.localizedDescription) }
    }
}

private extension SessionProfile {
    static var localForProxyValidation: SessionProfile { SessionProfile(name: "验证代理路由", host: "fixture.invalid", username: "fixture") }
}
