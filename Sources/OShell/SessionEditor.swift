// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class SessionEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var profile: SessionProfile
    private let original: SessionProfile?
    private let defaults: SessionDefaults
    private let profiles: [SessionProfile]
    private let alert = PopupAlert()
    private let pages = NSTabView()
    private let name = NSTextField(), directory = SessionDirectoryPicker(), host = NSTextField(), port = NSTextField(), user = NSTextField(), key = NSTextField()
    private let password = PasswordEntryView(identifier: "session.password"), remember = NSButton(checkboxWithTitle: "保存密码", target: nil, action: nil)
    private let passwordProtection = NSPopUpButton()
    private let proxyPicker = NSPopUpButton()
    private let proxyRouteNote = NSTextField(wrappingLabelWithString: "")
    private var proxyCatalog: [ProxyProfile]
    private let manageProxies: (() -> [ProxyProfile])?
    private let legacy = NSButton(checkboxWithTitle: "兼容 CentOS 6 / 旧版 SSH 服务", target: nil, action: nil)
    private let alive = NSButton(checkboxWithTitle: "发送 SSH 保持活动消息", target: nil, action: nil)
    private let interval = NSTextField(), missed = NSTextField()
    private let tcp = NSButton(checkboxWithTitle: "启用 TCP KeepAlive", target: nil, action: nil)
    private let idle = NSButton(checkboxWithTitle: "终端空闲时发送字符串", target: nil, action: nil)
    private let idleInterval = NSTextField(), idleText = NSTextField()
    private let quick = NSButton(checkboxWithTitle: "显示在顶部快捷连接菜单", target: nil, action: nil)
    private let titleMode = NSPopUpButton()
    private let titleModeNote = NSTextField(wrappingLabelWithString: "")
    var dialog: PopupAlert { alert }
    var pageTitles: [String] { pages.tabViewItems.map(\.label) }
    private let tunnels = NSTableView()
    let protocolKind = NSPopUpButton()
    private let remoteDirectory = NSTextField()
    private var allPages = [NSTabViewItem]()
    private var lastKind: SessionKind = .ssh
    init(_ existing: SessionProfile?, profiles: [SessionProfile], directories: [String], initialDirectory: String, kind: SessionKind = .ssh, defaults: SessionDefaults = SessionDefaults(), proxies: [ProxyProfile] = [], manageProxies: (() -> [ProxyProfile])? = nil) {
        proxyCatalog = proxies; self.manageProxies = manageProxies
        original = existing; profile = existing ?? defaults.makeProfile(kind: kind, directory: initialDirectory); self.profiles = profiles; self.defaults = defaults
        lastKind = profile.kind
        super.init()
        alert.messageText = existing == nil ? "新建会话" : "会话属性"
        alert.informativeText = "配置在下次新建连接时生效。密码可由 OShell 本机自动加密，无需主密码；也可选择主密码保护。会话密码仍保存在 OShell 配置中；主密码可另行启用 Touch ID 解锁。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        name.stringValue = profile.name; directory.configure(directories: directories, selected: profile.group)
        name.identifier = .init("session.name"); host.identifier = .init("session.host"); port.identifier = .init("session.port")
        user.identifier = .init("session.user"); interval.identifier = .init("session.keepAlive.interval")
        directory.identifier = .init("session.directory")
        host.stringValue = profile.host; host.placeholderString = "主机地址或 SSH 配置别名"
        port.stringValue = String(profile.port); user.stringValue = profile.username
        user.placeholderString = "留空使用 SSH 默认用户"
        key.stringValue = profile.identityFile; key.placeholderString = "可选，例如 ~/.ssh/id_rsa"
        password.placeholderString = profile.encryptedPassword == nil ? "留空则在连接时输入" : "已保存（不回显）；留空沿用，填写新值替换"
        remember.state = profile.encryptedPassword == nil ? .off : .on
        remember.identifier = .init("session.remember")
        passwordProtection.identifier = .init("session.passwordProtection")
        for popup in [passwordProtection] { popup.addItems(withTitles: PasswordProtection.allCases.map(\.title)) }
        passwordProtection.selectItem(at: profile.encryptedPassword != nil && profile.encryptedPassword?.localKeyID == nil ? 1 : 0)
        remember.target = self; remember.action = #selector(passwordStorageChanged)
        if PasswordVault.shared.masterProtectionEnabled {
            for popup in [passwordProtection] {
                popup.selectItem(at: 1); popup.autoenablesItems = false; popup.item(at: 0)?.isEnabled = false
            }
        }
        let passwordStorage = NSStackView(views: [remember, passwordProtection]); passwordStorage.spacing = 8
        legacy.state = profile.legacySSH ? .on : .off
        protocolKind.addItems(withTitles: ["SSH", "SFTP", "FTP"])
        protocolKind.selectItem(at: [.ssh, .sftp, .ftp].firstIndex(of: profile.kind) ?? 0)
        protocolKind.target = self; protocolKind.action = #selector(protocolChanged)
        remoteDirectory.stringValue = profile.initialDirectory
        addPage("连接", rows: [("协议", protocolKind), ("名称", name), ("目录", directory), ("主机", host), ("端口", port), ("用户名", user), ("私钥", key), ("密码", password), ("密码保存", passwordStorage), ("文件初始目录", remoteDirectory), ("兼容性", legacy)], note: "本机自动加密的密文和随机密钥均由 OShell 保存在数据目录，复制整个目录可能同时带走密钥。主密码模式保护更强。已保存密码不回显；留空并勾选保存密码时沿用，修改主机或账号后也会沿用。填写新值可替换，取消勾选可清除。")
        proxyRouteNote.maximumNumberOfLines = 3; proxyRouteNote.lineBreakMode = .byTruncatingMiddle
        proxyPicker.identifier = .init("session.sharedProxy")
        proxyPicker.target = self; proxyPicker.action = #selector(proxyChanged)
        reloadProxies(selected: profile.proxyID)
        let manage = button("代理管理…", #selector(openProxyManager)); manage.isEnabled = manageProxies != nil
        addPage("代理", rows: [("共享代理", proxyPicker), ("", manage), ("连接链路", proxyRouteNote)], note: "多个会话可选择同一代理。代理管理中配置认证与上级代理；连接顺序从本机开始，最多 8 级。修改在下次新连接时生效。")
        let tunnelPage = NSView()
        let note = label("连接建立后自动应用启用的转发规则，可配置本地、远程及动态 SOCKS 转发。")
        for (id, title, width) in [("kind", "类型", 110.0), ("source", "监听地址", 160.0), ("target", "目标", 180.0), ("note", "说明", 130.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; tunnels.addTableColumn(column)
        }
        tunnels.rowHeight = 28; tunnels.delegate = self; tunnels.dataSource = self
        tunnels.target = self; tunnels.doubleAction = #selector(editTunnel)
        let scroll = NSScrollView(); scroll.documentView = tunnels; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let buttons = NSStackView(views: [button("添加规则", #selector(addTunnel)), button("编辑", #selector(editTunnel)), button("删除", #selector(removeTunnel))]); buttons.spacing = 8
        [note, scroll, buttons].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; tunnelPage.addSubview($0) }
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: tunnelPage.topAnchor, constant: 18), note.leadingAnchor.constraint(equalTo: tunnelPage.leadingAnchor, constant: 18), note.trailingAnchor.constraint(equalTo: tunnelPage.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 18), scroll.leadingAnchor.constraint(equalTo: note.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: note.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10), buttons.leadingAnchor.constraint(equalTo: note.leadingAnchor), buttons.bottomAnchor.constraint(equalTo: tunnelPage.bottomAnchor, constant: -18)])
        let tunnelItem = NSTabViewItem(identifier: "隧道"); tunnelItem.label = "隧道"; tunnelItem.view = tunnelPage; pages.addTabViewItem(tunnelItem)
        alive.state = profile.keepAlive.enabled ? .on : .off; interval.stringValue = String(profile.keepAlive.interval); missed.stringValue = String(profile.keepAlive.maxMissed)
        tcp.state = profile.keepAlive.tcp ? .on : .off; idle.state = profile.keepAlive.idleEnabled ? .on : .off
        idleInterval.stringValue = String(profile.keepAlive.idleInterval); idleText.stringValue = profile.keepAlive.idleText
        addPage("保持活动", rows: [("默认配置", button("使用全局默认", #selector(useDefaultKeepAlive))), ("", alive), ("间隔（秒）", interval), ("最大未响应次数", missed), ("", tcp), ("", idle), ("空闲间隔（秒）", idleInterval), ("发送字符串", idleText)], note: "空闲字符串在登录成功后发送到终端，可执行命令；支持 \\n、\\r、\\t、\\e、\\\\。输入、输出或文件传输期间不发送。SSH 保活消息不会输入命令。默认属性可在会话管理右键菜单中配置；点击使用默认后需保存才生效。")
        [alive, idle].forEach { $0.target = self; $0.action = #selector(keepAliveChanged) }
        quick.state = profile.quickConnect ? .on : .off
        titleMode.identifier = .init("session.titleMode")
        titleMode.addItems(withTitles: SessionTitleDisplayMode.allCases.map(\.title))
        let titleSettings = (try? SessionTitleSettings.load()) ?? .init()
        titleMode.selectItem(at: SessionTitleDisplayMode.allCases.firstIndex(of: existing == nil ? titleSettings.defaultMode : titleSettings.mode(for: profile))!)
        titleMode.target = self; titleMode.action = #selector(titleModeChanged)
        titleModeNote.font = .systemFont(ofSize: 11); titleModeNote.textColor = .secondaryLabelColor
        titleModeChanged()
        addPage("标签与快捷连接", rows: [("", quick), ("标题识别方式", titleMode), ("", titleModeNote)], note: "可使用会话名称或主机识别方式；标题选择仅保存在本机，保存后已打开的标签立即生效。悬停可查看主机、地址、端口、用户名及实际连接对端；连接参数仍在下次连接生效。")
        pages.frame = NSRect(x: 0, y: 0, width: 680, height: 500); alert.accessoryView = pages
        alert.window.initialFirstResponder = name
        allPages = pages.tabViewItems; protocolChanged(); proxyChanged(); keepAliveChanged()
    }
    var selectedTitleMode: SessionTitleDisplayMode { SessionTitleDisplayMode.allCases[titleMode.indexOfSelectedItem] }
    @objc private func titleModeChanged() { titleModeNote.stringValue = selectedTitleMode.explanation }
    private func label(_ text: String) -> NSTextField { let view = NSTextField(wrappingLabelWithString: text); view.font = .systemFont(ofSize: 11); view.textColor = .secondaryLabelColor; return view }
    private func button(_ text: String, _ action: Selector) -> NSButton { let b = NSButton(title: text, target: self, action: action); b.bezelStyle = .rounded; return b }
    private func addPage(_ title: String, rows: [(String, NSView)], note: String? = nil) {
        let view = NSView(), grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing; grid.column(at: 0).width = 140; grid.column(at: 1).xPlacement = .fill; grid.rowSpacing = 12; grid.columnSpacing = 14
        for (_, control) in rows {
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        grid.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(grid)
        NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 22), grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18), grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)])
        if let note {
            let text = label(note); text.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(text)
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: grid.leadingAnchor), text.trailingAnchor.constraint(equalTo: grid.trailingAnchor), text.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20)])
        }
        let item = NSTabViewItem(identifier: title); item.label = title; item.view = view; pages.addTabViewItem(item)
    }
    @objc func protocolChanged() {
        let kind: SessionKind = [.ssh, .sftp, .ftp][protocolKind.indexOfSelectedItem]
        if kind != lastKind {
            if original == nil {
                let before = defaults.makeProfile(kind: lastKind, directory: ""), next = defaults.makeProfile(kind: kind, directory: "")
                if port.stringValue == String(before.port) { port.stringValue = String(next.port) }
                if user.stringValue == before.username { user.stringValue = next.username }
                if remoteDirectory.stringValue == before.initialDirectory { remoteDirectory.stringValue = next.initialDirectory }
            } else {
                if port.stringValue == String(lastKind == .ftp ? 21 : 22) { port.stringValue = String(kind == .ftp ? 21 : 22) }
                if kind == .ftp && remoteDirectory.stringValue == "." { remoteDirectory.stringValue = "/" }
            }
        }
        lastKind = kind
        key.isEnabled = kind.usesSSH; legacy.isEnabled = kind.usesSSH
        titleMode.isEnabled = kind == .ssh
        host.placeholderString = kind == .ftp ? "FTP 主机地址" : "主机地址或 SSH 配置别名"
        user.placeholderString = kind == .ftp ? "例如 anonymous" : "留空使用 SSH 默认用户"
        for item in pages.tabViewItems { pages.removeTabViewItem(item) }
        for item in allPages {
            if kind == .ftp && ["代理", "隧道", "保持活动"].contains(item.label) { continue }
            if kind == .sftp && item.label == "隧道" { continue }
            pages.addTabViewItem(item)
        }
        keepAliveChanged()
    }
    private func reloadProxies(selected: UUID?) {
        proxyPicker.removeAllItems(); proxyPicker.addItem(withTitle: "无代理（直连）")
        if profile.proxy.kind != .none || !profile.jumpHost.isEmpty {
            proxyPicker.addItem(withTitle: "当前独立代理 / 旧跳板机（兼容）"); proxyPicker.lastItem?.representedObject = "legacy"
        }
        for (index, entry) in proxyCatalog.enumerated() { proxyPicker.addItem(withTitle: "\(index + 1). " + entry.name); proxyPicker.lastItem?.representedObject = entry.id.uuidString }
        if let selected, let item = proxyPicker.itemArray.first(where: { ($0.representedObject as? String) == selected.uuidString }) { proxyPicker.select(item) }
        else if let selected { proxyPicker.addItem(withTitle: "代理已缺失，请重新选择"); proxyPicker.lastItem?.representedObject = selected.uuidString; proxyPicker.selectItem(at: proxyPicker.numberOfItems - 1) }
        else if let item = proxyPicker.itemArray.first(where: { ($0.representedObject as? String) == "legacy" }) { proxyPicker.select(item) }
        proxyChanged()
    }
    @objc private func openProxyManager() {
        let selected = (proxyPicker.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:))
        if let manageProxies { proxyCatalog = manageProxies(); reloadProxies(selected: selected) }
    }
    @objc private func proxyChanged() {
        if let id = (proxyPicker.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:)) {
            do { proxyRouteNote.stringValue = "本机 → " + (try ProxyCatalog.route(id, in: proxyCatalog)).map(\.name).joined(separator: " → ") + " → 当前会话" }
            catch { proxyRouteNote.stringValue = error.localizedDescription }
        } else { proxyRouteNote.stringValue = (proxyPicker.selectedItem?.representedObject as? String) == "legacy" ? "保留原有连接路径；可在代理管理中建立共享代理后替换。" : "本机 → 当前会话" }
        proxyRouteNote.toolTip = proxyRouteNote.stringValue
    }
    @objc private func passwordStorageChanged() { passwordProtection.isEnabled = remember.state == .on }
    @objc private func keepAliveChanged() {
        interval.isEnabled = alive.state == .on; missed.isEnabled = alive.state == .on
        idle.isEnabled = lastKind == .ssh
        idleInterval.isEnabled = lastKind == .ssh && idle.state == .on; idleText.isEnabled = idleInterval.isEnabled
    }
    @objc func useDefaultKeepAlive() {
        let value = defaults.keepAlive
        alive.state = value.enabled ? .on : .off; interval.stringValue = String(value.interval); missed.stringValue = String(value.maxMissed)
        tcp.state = value.tcp ? .on : .off; idle.state = lastKind == .ssh && value.idleEnabled ? .on : .off
        idleInterval.stringValue = String(value.idleInterval); idleText.stringValue = value.idleText
        keepAliveChanged()
    }
    func run() -> SessionProfile? {
        defer { password.clear() }
        while alert.runModal() == .alertFirstButtonReturn {
            profile.kind = [.ssh, .sftp, .ftp][protocolKind.indexOfSelectedItem]
            profile.initialDirectory = remoteDirectory.stringValue
            profile.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); profile.port = Int(port.stringValue) ?? 0
            profile.username = user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); profile.identityFile = key.stringValue
            let chosenProxy = proxyPicker.selectedItem?.representedObject as? String
            if chosenProxy != "legacy" {
                profile.proxyID = chosenProxy.flatMap(UUID.init(uuidString:)); profile.proxy = ProxySettings(); profile.jumpHost = ""
            }
            profile.legacySSH = legacy.state == .on
            profile.keepAlive.enabled = alive.state == .on; profile.keepAlive.interval = Int(interval.stringValue) ?? 0; profile.keepAlive.maxMissed = Int(missed.stringValue) ?? 0
            profile.keepAlive.tcp = tcp.state == .on; profile.keepAlive.idleEnabled = profile.kind == .ssh && idle.state == .on
            profile.keepAlive.idleInterval = Int(idleInterval.stringValue) ?? 0; profile.keepAlive.idleText = idleText.stringValue
            profile.quickConnect = quick.state == .on
            if profile.kind == .ftp {
                profile.identityFile = ""; profile.jumpHost = ""; profile.proxy = ProxySettings(); profile.proxyID = nil; profile.tunnels = []; profile.legacySSH = false; profile.keepAlive = KeepAliveSettings()
            }
            do {
                profile.group = directory.selectedDirectory
                try profile.validate()
                if let id = profile.proxyID { _ = try ProxyCatalog.route(id, in: proxyCatalog) }
                let known = profiles + profiles.filter { $0.proxy.encryptedPassword != nil }.map { $0.proxy.credentialProfile }
                func protect(_ input: String, destination: SessionProfile, old: SessionProfile?, selection: NSPopUpButton, explicitIdentity: Bool) throws -> EncryptedPassword? {
                    let mode = PasswordProtection.allCases[selection.indexOfSelectedItem]
                    var secret = input
                    var identity: SSHIdentity? = explicitIdentity ? SSHIdentity(host: destination.host, user: destination.username, port: destination.port) : nil
                    if secret.isEmpty {
                        guard let old, let envelope = old.encryptedPassword else { throw ModelError.invalid("请填写要保存的密码。"); }
                        let sameTarget = old.host == destination.host && old.port == destination.port && old.username == destination.username && old.kind.usesSSH == destination.kind.usesSSH
                        let oldMode: PasswordProtection = envelope.localKeyID == nil ? .master : .local
                        if sameTarget && mode == oldMode { return PasswordVault.shared.currentCredential(old).encryptedPassword }
                        let resolved = try identity ?? SSHIdentity.resolve(destination)
                        if sameTarget && resolved != envelope.identity { throw ModelError.invalid("SSH 配置解析出的目标已改变，请重新输入密码。") }
                        identity = resolved
                        guard let value = try PasswordVault.shared.readSavedPassword(old) else { return nil }; secret = value
                    }
                    return try PasswordVault.shared.protect(secret, profile: destination, knownProfiles: known, protection: mode,
                        identity: identity)
                }
                if remember.state == .on {
                    guard let encrypted = try protect(password.stringValue, destination: profile, old: original, selection: passwordProtection, explicitIdentity: profile.kind == .ftp) else { continue }
                    profile.encryptedPassword = encrypted
                } else { profile.encryptedPassword = nil }
                return profile
            } catch { Dialogs.message(error.localizedDescription) }
        }
        return nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { profile.tunnels.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = profile.tunnels[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "kind": text = (rule.enabled ? "" : "已停用 · ") + rule.kind.title
        case "source": text = "\(rule.bindHost):\(rule.listenPort)"
        case "target": text = rule.kind == .dynamic ? "SOCKS4/5" : "\(rule.destinationHost):\(rule.destinationPort)"
        default: text = rule.note
        }
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingMiddle; return label
    }
    @objc private func addTunnel() { if let rule = Self.tunnel(nil) { profile.tunnels.append(rule); tunnels.reloadData() } }
    @objc private func editTunnel() { let row = tunnels.selectedRow; if profile.tunnels.indices.contains(row), let rule = Self.tunnel(profile.tunnels[row]) { profile.tunnels[row] = rule; tunnels.reloadData() } }
    @objc private func removeTunnel() { let row = tunnels.selectedRow; if profile.tunnels.indices.contains(row) { profile.tunnels.remove(at: row); tunnels.reloadData() } }
    private static func tunnel(_ original: TunnelRule?) -> TunnelRule? {
        var rule = original ?? TunnelRule()
        let alert = PopupAlert(); alert.messageText = "隧道转发规则"; alert.informativeText = "监听地址默认 127.0.0.1；使用 0.0.0.0 会允许其他主机访问。远程监听还受服务器 GatewayPorts 设置限制。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let enabled = NSButton(checkboxWithTitle: "启用此规则", target: nil, action: nil); enabled.state = rule.enabled ? .on : .off
        let kind = NSPopUpButton(); kind.addItems(withTitles: TunnelKind.allCases.map(\.title)); kind.selectItem(at: TunnelKind.allCases.firstIndex(of: rule.kind)!)
        let bind = NSTextField(string: rule.bindHost), port = NSTextField(string: String(rule.listenPort)), destination = NSTextField(string: rule.destinationHost), targetPort = NSTextField(string: String(rule.destinationPort)), note = NSTextField(string: rule.note)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "类型"), kind], [NSTextField(labelWithString: "监听地址"), bind], [NSTextField(labelWithString: "监听端口"), port], [NSTextField(labelWithString: "目标主机（动态模式忽略）"), destination], [NSTextField(labelWithString: "目标端口"), targetPort], [NSTextField(labelWithString: "说明"), note], [NSTextField(labelWithString: ""), enabled]])
        grid.rowSpacing = 12; grid.columnSpacing = 12; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 0).width = 180; grid.column(at: 1).xPlacement = .fill; grid.frame = NSRect(x: 0, y: 0, width: 550, height: 260); alert.accessoryView = grid
        while alert.runModal() == .alertFirstButtonReturn {
            rule.kind = TunnelKind.allCases[kind.indexOfSelectedItem]; rule.enabled = enabled.state == .on
            rule.bindHost = bind.stringValue; rule.listenPort = Int(port.stringValue) ?? 0; rule.destinationHost = destination.stringValue; rule.destinationPort = Int(targetPort.stringValue) ?? 0; rule.note = note.stringValue
            do { try rule.validate(); return rule } catch { Dialogs.message(error.localizedDescription) }
        }
        return nil
    }
}
