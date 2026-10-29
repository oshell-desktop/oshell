// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class ProxyManager: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let workspace: WorkspaceController
    private let table = NSTableView()
    init(workspace: WorkspaceController) { self.workspace = workspace; super.init() }
    func run() {
        let alert = PopupAlert(); alert.messageText = "代理管理"
        alert.informativeText = "代理可被多个 SSH / SFTP 会话共用。选择上级代理可组成最多 8 级链路；修改在新连接时生效，现有连接不重建。私钥文件只保存在本机。"
        alert.addButton(withTitle: "关闭")
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 350))
        for (id, title, width) in [("name","名称",190.0),("kind","类型",110.0),("host","主机",210.0),("via","上级代理",180.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.rowHeight = 26; table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(edit)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 42, width: 760, height: 308)); scroll.documentView = table; scroll.hasVerticalScroller = true; AppUI.styleScrollSurface(scroll)
        root.addSubview(scroll)
        for (index, item) in [("新增",#selector(add)),("编辑",#selector(edit)),("删除",#selector(remove))].enumerated() {
            let button = NSButton(title: item.0, target: self, action: item.1); button.bezelStyle = .rounded
            button.frame = NSRect(x: CGFloat(index * 86), y: 2, width: 80, height: 30); root.addSubview(button)
        }
        alert.accessoryView = root; _ = alert.runModal()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { workspace.configuration.proxies.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let proxy = workspace.configuration.proxies[row], value: String
        switch column?.identifier.rawValue {
        case "name": value = proxy.name
        case "kind": value = proxy.settings.kind.title
        case "host": value = proxy.settings.host + ":" + String(proxy.settings.port)
        default: value = workspace.configuration.proxies.first { $0.id == proxy.upstreamID }?.name ?? "直连"
        }
        let field = NSTextField(labelWithString: value); field.lineBreakMode = .byTruncatingMiddle; return field
    }
    @objc private func add() { save(nil) }
    @objc private func edit() { if workspace.configuration.proxies.indices.contains(table.selectedRow) { save(workspace.configuration.proxies[table.selectedRow]) } }
    private func save(_ proxy: ProxyProfile?) {
        guard let value = ProxyEditor(proxy, workspace: workspace).run() else { return }
        var config = workspace.configuration
        if let index = config.proxies.firstIndex(where: { $0.id == value.id }) { config.proxies[index] = value } else { config.proxies.append(value) }
        if workspace.saveConfiguration(config) { table.reloadData() }
    }
    @objc private func remove() {
        guard workspace.configuration.proxies.indices.contains(table.selectedRow) else { return }
        let selected = workspace.configuration.proxies[table.selectedRow], config = workspace.configuration
        let sessions = config.profiles.filter { $0.proxyID == selected.id }.count
        let proxies = config.proxies.filter { $0.upstreamID == selected.id }.count
        guard sessions == 0 && proxies == 0 else { Dialogs.message("还有 \(sessions) 个会话、\(proxies) 个代理引用此项，请先更换它们的代理配置。"); return }
        guard Dialogs.confirm("删除代理“\(selected.name)”？", text: "现有连接继续运行。", action: "删除") else { return }
        var next = config; next.proxies.removeAll { $0.id == selected.id }
        if workspace.saveConfiguration(next) { table.reloadData() }
    }
}

final class ProxyEditor: NSObject {
    private unowned let workspace: WorkspaceController
    private let original: ProxyProfile?
    private var proxy: ProxyProfile
    private let kind = NSPopUpButton(), auth = NSPopUpButton(), upstream = NSPopUpButton(), protection = NSPopUpButton()
    private let name = NSTextField(), host = NSTextField(), port = NSTextField(), user = NSTextField(), key = NSTextField(), password = NSSecureTextField()
    private let remember = NSButton(checkboxWithTitle: "保存代理密码", target: nil, action: nil)
    private let route = NSTextField(wrappingLabelWithString: "")
    private var choices = [ProxyProfile]()
    private var lastKind: ProxyKind = .none
    private let browse = NSButton(title: "选择…", target: nil, action: nil)
    init(_ value: ProxyProfile?, workspace: WorkspaceController) {
        self.workspace = workspace; original = value; proxy = value ?? ProxyProfile(name: "新代理")
        if value == nil { proxy.settings.kind = .socks5 }
        super.init()
        name.stringValue = proxy.name; host.stringValue = proxy.settings.host; port.stringValue = String(proxy.settings.port); user.stringValue = proxy.settings.username; key.stringValue = proxy.settings.identityFile
        kind.addItems(withTitles: ProxyKind.allCases.filter { $0 != .none }.map(\.title)); kind.selectItem(withTitle: proxy.settings.kind.title)
        auth.addItems(withTitles: ProxySSHAuthentication.allCases.map(\.title)); auth.selectItem(withTitle: proxy.settings.sshAuthentication.title)
        protection.addItems(withTitles: PasswordProtection.allCases.map(\.title)); protection.selectItem(at: proxy.settings.encryptedPassword?.localKeyID == nil && proxy.settings.encryptedPassword != nil ? 1 : 0)
        if PasswordVault.shared.masterProtectionEnabled { protection.selectItem(at: 1); protection.autoenablesItems = false; protection.item(at: 0)?.isEnabled = false }
        remember.state = proxy.settings.encryptedPassword == nil ? .off : .on
        password.placeholderString = proxy.settings.encryptedPassword == nil ? "留空则在连接时询问" : "已保存，留空保留；填写新值替换"
        key.placeholderString = "私钥文件路径；加密私钥的口令在连接时输入"
        choices = workspace.configuration.proxies.filter { $0.id != proxy.id }
        upstream.addItem(withTitle: "无（直接连接此代理）"); upstream.addItems(withTitles: choices.enumerated().map { "\($0.offset + 1). " + $0.element.name })
        if let index = choices.firstIndex(where: { $0.id == proxy.upstreamID }) { upstream.selectItem(at: index + 1) }
        for control in [kind, auth, upstream, remember] as [NSControl] { control.target = self; control.action = #selector(changed) }
        for (field, id) in [(name,"name"),(host,"host"),(port,"port"),(user,"user"),(key,"key"),(password,"password")] { field.identifier = .init("proxy." + id) }
        kind.identifier = .init("proxy.kind"); auth.identifier = .init("proxy.auth"); upstream.identifier = .init("proxy.upstream")
        lastKind = proxy.settings.kind; browse.target = self; browse.action = #selector(chooseKey); browse.bezelStyle = .rounded
        route.maximumNumberOfLines = 2; route.lineBreakMode = .byTruncatingMiddle
        changed()
    }
    @objc private func chooseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.title = "选择 SSH 跳板机私钥"
        if panel.runPopupModal() == .OK, let url = panel.url { key.stringValue = url.path }
    }
    @objc private func changed() {
        let selected = ProxyKind.allCases.filter { $0 != .none }[kind.indexOfSelectedItem]
        auth.isEnabled = selected == .jump
        let authMode = ProxySSHAuthentication.allCases[auth.indexOfSelectedItem]
        key.isEnabled = selected == .jump && authMode != .password; browse.isEnabled = key.isEnabled
        if selected != lastKind {
            let oldPort = lastKind == .jump ? 22 : 1080
            if port.stringValue == String(oldPort) { port.stringValue = selected == .jump ? "22" : "1080" }
            lastKind = selected
        }
        remember.isEnabled = [.socks5,.http].contains(selected) || (selected == .jump && authMode != .privateKey)
        password.isEnabled = remember.isEnabled; protection.isEnabled = remember.isEnabled && remember.state == .on
        let id = upstream.indexOfSelectedItem > 0 ? choices[upstream.indexOfSelectedItem - 1].id : nil
        var draft = proxy; draft.upstreamID = id
        do { route.stringValue = "链路：本机 → " + (try ProxyCatalog.route(draft.id, in: choices + [draft])).map(\.name).joined(separator: " → ") + " → 目标会话" }
        catch { route.stringValue = error.localizedDescription }
        route.toolTip = route.stringValue
    }
    func run() -> ProxyProfile? {
        let alert = PopupAlert(); alert.messageText = original == nil ? "新增共享代理" : "编辑共享代理"
        alert.informativeText = "上级代理用于连接当前代理；支持 SSH、SOCKS、HTTP CONNECT 混合链路。密码分别加密保存，私钥内容不会复制或同步。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let keyRow = NSStackView(views: [key,browse]); keyRow.spacing = 8
        let saved = NSStackView(views: [remember,protection]); saved.spacing = 8
        let rows: [(String,NSView)] = [("名称",name),("类型",kind),("主机",host),("端口",port),("用户名",user),("SSH 认证",auth),("私钥",keyRow),("密码",password),("密码保护",saved),("上级代理",upstream),("连接顺序",route)]
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0),$0.1] })
        grid.column(at: 0).width = 90; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .fill; grid.rowSpacing = 10; grid.columnSpacing = 12
        grid.frame = NSRect(x: 0,y: 0,width: 650,height: 375); alert.accessoryView = grid
        defer { password.stringValue = "" }
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                proxy.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                proxy.settings.kind = ProxyKind.allCases.filter { $0 != .none }[kind.indexOfSelectedItem]
                proxy.settings.host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); proxy.settings.port = Int(port.stringValue) ?? 0; proxy.settings.username = user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                proxy.settings.identityFile = key.isEnabled ? key.stringValue : ""
                proxy.settings.sshAuthentication = ProxySSHAuthentication.allCases[auth.indexOfSelectedItem]
                proxy.upstreamID = upstream.indexOfSelectedItem > 0 ? choices[upstream.indexOfSelectedItem - 1].id : nil
                try ProxyCatalog.validate(workspace.configuration.proxies.filter { $0.id != proxy.id } + [proxy], sessions: workspace.configuration.profiles)
                if remember.isEnabled && remember.state == .on && proxy.settings.supportsPassword {
                    let mode = PasswordProtection.allCases[protection.indexOfSelectedItem], target = proxy.settings.credentialProfile
                    if password.stringValue.isEmpty, let old = original?.settings, old.encryptedPassword != nil {
                        guard old.host == proxy.settings.host, old.port == proxy.settings.port, old.username == proxy.settings.username, old.kind == proxy.settings.kind else { throw ModelError.invalid("代理目标已改变，请重新输入密码或取消保存。") }
                        if (old.encryptedPassword?.localKeyID == nil) == (mode == .master) { proxy.settings.encryptedPassword = PasswordVault.shared.currentCredential(old.credentialProfile).encryptedPassword }
                        else {
                            guard let secret = try PasswordVault.shared.readSavedPassword(old.credentialProfile) else { continue }
                            proxy.settings.encryptedPassword = try PasswordVault.shared.protect(secret, profile: target, knownProfiles: workspace.credentialProfiles, protection: mode, identity: old.encryptedPassword?.identity)
                        }
                    } else {
                        guard !password.stringValue.isEmpty, !target.username.isEmpty else { throw ModelError.invalid("保存代理密码需要用户名和密码。") }
                        let identity = proxy.settings.kind == .jump ? try SSHIdentity.resolve(target) : SSHIdentity(host: target.host, user: target.username, port: target.port)
                        proxy.settings.encryptedPassword = try PasswordVault.shared.protect(password.stringValue, profile: target, knownProfiles: workspace.credentialProfiles, protection: mode, identity: identity)
                    }
                    guard proxy.settings.encryptedPassword != nil else { continue }
                } else { proxy.settings.encryptedPassword = nil }
                return proxy
            } catch { Dialogs.message(error.localizedDescription) }
        }
        return nil
    }
}
extension WorkspaceController {
    @objc func showProxyManager() { ProxyManager(workspace: self).run() }
    func manageProxiesForEditor() -> [ProxyProfile] { showProxyManager(); return configuration.proxies }
}
