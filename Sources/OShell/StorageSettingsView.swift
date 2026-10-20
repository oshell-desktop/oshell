// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class StorageSettingsView: NSView {
    private enum SyncMethod: Int { case off, directory, webDAV }
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let scroll = NSScrollView(), document = Document()
    private var contentStack: NSStackView?
    private weak var workspace: WorkspaceController?
    private let location = StorageLocation(base: StorageLocation.localStateDirectory)
    private let current: URL
    private let method = NSPopUpButton()
    private let directoryFields = NSStackView(), davFields = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let selectionHint = NSTextField(wrappingLabelWithString: "")
    private let certificateControls = NSStackView()
    private let details = NSStackView()
    private let davStatus = NSTextField(wrappingLabelWithString: "")
    private let address = NSTextField(), username = NSTextField(), password = NSSecureTextField()
    private var trustedCertificate: WebDAVCertificateTrust?
    private var pendingCertificate: WebDAVCertificateIssue?
    private let certificateStatus = NSTextField(wrappingLabelWithString: "")
    private let trustCertificate = NSButton(title: "信任此服务器证书…", target: nil, action: nil)
    private let forgetCertificate = NSButton(title: "取消证书信任", target: nil, action: nil)
    private var directoryPath: String?
    private(set) var changed = false
    private var davChanged = false, testing = false
    private var loadError: String?
    private let isolated: Bool
    private var originalSettings: [String: Data] = [:]
    private var settingsFiles: [URL] { [current.appendingPathComponent("storage-location.json"), WebDAVSync.settingsURL] }
    private var selectedMethod: SyncMethod { SyncMethod(rawValue: method.indexOfSelectedItem) ?? .off }

    init(workspace: WorkspaceController) {
        self.workspace = workspace; current = workspace.store.url.deletingLastPathComponent()
        isolated = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] != nil
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        func label(_ text: String, title: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: title ? 14 : 12, weight: title ? .semibold : .regular); return field
        }
        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
        }
        method.addItems(withTitles: ["不启用同步", "同步目录（iCloud / 自定义目录）", "WebDAV"])
        method.identifier = .init("storage.syncMethod"); method.target = self; method.action = #selector(methodChanged)
        let methodRow = NSStackView(views: [label("同步方式", title: true), method]); methodRow.spacing = 18
        let choose = button("选择文件夹…", #selector(chooseDirectory)); choose.isEnabled = !isolated; choose.identifier = .init("storage.chooseDirectory")
        directoryFields.identifier = .init("storage.directoryFields"); davFields.identifier = .init("storage.webdavFields")
        for stack in [directoryFields, davFields] { stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10 }
        directoryFields.addArrangedSubview(label("选择所有设备共同访问的文件夹，可使用 iCloud Drive。自动识别新建或已有同步配置。")); directoryFields.addArrangedSubview(status); directoryFields.addArrangedSubview(choose)
        address.placeholderString = "https://服务器/WebDAV/OShell/（服务器上已存在的目录）"
        username.placeholderString = "WebDAV 账号"; password.placeholderString = "WebDAV 密码 / 应用专用密码"
        address.identifier = .init("webdav.address"); username.identifier = .init("webdav.username"); password.identifier = .init("webdav.password")
        for field in [address, username, password] { field.delegate = self }
        let probe = button("测试连接", #selector(testConnection))
        trustCertificate.target = self; trustCertificate.action = #selector(trustServerCertificate)
        forgetCertificate.target = self; forgetCertificate.action = #selector(forgetServerCertificate)
        trustCertificate.identifier = .init("webdav.trustCertificate"); forgetCertificate.identifier = .init("webdav.forgetCertificate")
        trustCertificate.bezelStyle = .rounded; forgetCertificate.bezelStyle = .rounded
        certificateControls.addArrangedSubview(trustCertificate); certificateControls.addArrangedSubview(forgetCertificate); certificateControls.spacing = 8
        certificateStatus.font = .systemFont(ofSize: 12); certificateStatus.isSelectable = true
        certificateStatus.identifier = .init("webdav.certificateStatus")
        for v in [address, username, password, probe, davStatus, certificateStatus, certificateControls] { davFields.addArrangedSubview(v) }
        let intro = label("先选择一种同步方式，再配置同步位置。多台设备使用同一位置和相同主密码；仅同步会话、目录、快捷链接、代理和加密密码。客户端设置保留在本机。")
        let help = label("点击“应用”生效，无需重启；首次接入和同步冲突仍需确认。启用时会引导设置或解锁主密码。")
        let localPath = label("本机始终使用：" + current.path); localPath.isSelectable = true; localPath.identifier = .init("storage.current")
        let localActions = NSStackView(views: [button("打开本机目录", #selector(reveal)), button("设置 / 解锁主密码…", #selector(setupMaster))]); localActions.spacing = 8
        let syncCard = SyncStatusView(sync: workspace.windowCoordinator?.webDAV)
        syncCard.onLayoutChange = { [weak self] in self?.needsLayout = true }
        syncCard.onUnlock = { [weak self] in self?.setupMaster() }
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 12; details.isHidden = true
        for view in [localPath, localActions] { details.addArrangedSubview(view) }
        let detailButton = button("显示本机数据与安全选项", #selector(toggleDetails(_:)))
        help.textColor = .secondaryLabelColor; localPath.textColor = .secondaryLabelColor
        let separator = NSBox(); separator.boxType = .separator
        let stack = NSStackView(views: [syncCard, separator, label("同步配置", title: true), intro, methodRow, directoryFields, davFields, selectionHint, help, detailButton, details])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        scroll.frame = bounds; scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        document.frame = bounds; scroll.documentView = document; addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack); contentStack = stack
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22)])
        for view in [syncCard, intro, directoryFields, davFields, selectionHint, help, separator, details] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        for view in [localPath] { view.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true }
        status.widthAnchor.constraint(equalTo: directoryFields.widthAnchor).isActive = true
        for view in [address, username, password, davStatus, certificateStatus] { view.widthAnchor.constraint(equalTo: davFields.widthAnchor).isActive = true }
        loadSettings()
        updateStatus(); updateCertificateStatus()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); document.setFrameSize(NSSize(width: scroll.contentSize.width, height: document.frame.height)); document.layoutSubtreeIfNeeded()
        let height = max(scroll.contentSize.height, (contentStack?.fittingSize.height ?? 0) + 44)
        if abs(document.frame.height - height) > 0.5 { document.setFrameSize(NSSize(width: document.frame.width, height: height)) }
    }
    private func loadSettings() {
        do {
            originalSettings = [:]
            for url in settingsFiles { originalSettings[url.path] = try SharedDataFile.readIfPresent(url) }
            let sync = workspace?.windowCoordinator?.webDAV
            if let pending = try location.pending() { directoryPath = pending.path }
            else { directoryPath = try location.syncDirectory()?.path }
            method.selectItem(at: sync?.enabled == true ? SyncMethod.webDAV.rawValue : (directoryPath == nil ? SyncMethod.off.rawValue : SyncMethod.directory.rawValue))
            if sync?.enabled == true {
                guard let master = PasswordVault.shared.cachedMaster else { throw ModelError.invalid("请先解锁主密码，以读取已保存的连接设置。") }
                if let dav = try sync?.settings(master: master) {
                    address.stringValue = dav.address; username.stringValue = dav.username; password.stringValue = dav.password; trustedCertificate = dav.trustedServerCertificate
                }
            }
            loadError = nil
        } catch { loadError = error.localizedDescription; selectionHint.stringValue = error.localizedDescription }
    }
    private func master() throws -> String {
        guard let workspace else { throw ModelError.invalid("工作区已关闭。") }
        try SharingProtection.require(workspace.configuration)
        guard let value = PasswordVault.shared.cachedMaster else { throw ModelError.invalid("尚未解锁主密码。") }
        return value
    }
    private func ensureMaster() throws -> String {
        if (try? master()) == nil { setupMaster() }
        return try master()
    }
    @objc private func setupMaster() {
        guard let workspace else { return }
        if !workspace.configuration.hasMasterPassword { workspace.setupMasterPassword() }
        else if let master = PasswordVault.shared.masterForImport(hasSavedPasswords: true) {
            if ConfigurationCredentials.profiles(in: workspace.configuration).contains(where: { $0.encryptedPassword?.localKeyID != nil }) {
                do { _ = try workspace.enableMasterProtection(master) } catch { Dialogs.message(error.localizedDescription) }
            }
        }
        if loadError != nil { loadSettings() }
        workspace.windowCoordinator?.webDAV.readinessChanged(); workspace.windowCoordinator?.webDAV.schedule()
        updateStatus()
    }
    private func updateStatus() {
        status.font = .systemFont(ofSize: 12); davStatus.font = .systemFont(ofSize: 12)
        status.stringValue = directoryPath ?? "尚未选择文件夹（可选 iCloud Drive 中的文件夹）"
        directoryFields.isHidden = selectedMethod != .directory; davFields.isHidden = selectedMethod != .webDAV
        selectionHint.isHidden = selectionHint.stringValue.isEmpty
        davStatus.isHidden = davStatus.stringValue.isEmpty
        needsLayout = true
    }
    @objc private func toggleDetails(_ sender: NSButton) {
        details.isHidden.toggle(); sender.title = details.isHidden ? "显示本机数据与安全选项" : "收起本机数据与安全选项"; needsLayout = true
    }
    @objc private func methodChanged() {
        changed = true
        selectionHint.stringValue = selectedMethod == .off ? "应用后停止同步，本机与共享位置的数据均保留。" : "更改将在点击“应用”后生效；当前同步位置的数据保留。"
        pendingCertificate = nil; davStatus.stringValue = ""
        updateStatus(); updateCertificateStatus()
    }
    @objc private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.title = "选择同步文件夹（自动识别已有配置）"
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        panel.directoryURL = directoryPath.map { URL(fileURLWithPath: $0) } ?? (FileManager.default.fileExists(atPath: cloud.path) ? cloud : current)
        guard panel.runPopupModal() == .OK, let url = panel.url else { return }
        directoryPath = url.resolvingSymlinksInPath().path; changed = true; updateStatus()
    }
    @objc private func reveal() { NSWorkspace.shared.open(current) }
    private func davSettings() throws -> WebDAVSettings {
        var settings = WebDAVSettings(address: address.stringValue, username: username.stringValue, password: password.stringValue)
        let url = try settings.directory()
        if trustedCertificate?.matches(url) == true { settings.trustedServerCertificate = trustedCertificate }
        return settings
    }
    private func updateCertificateStatus() {
        let url = try? WebDAVSettings(address: address.stringValue, username: "", password: "").directory()
        let active = url.flatMap { value in trustedCertificate.flatMap { $0.matches(value) ? $0 : nil } }
        certificateStatus.stringValue = active.map { "已保存此服务器证书信任（仅本机）\n\($0.endpoint) · \($0.subject)\nSHA-256：\($0.fingerprint)\n更改需点击“应用”保存。" } ?? "使用 macOS 默认信任；未受信任时先测试连接，再核对并信任证书。信任仅保存在本机，不参与会话同步。"
        trustCertificate.isEnabled = !testing && pendingCertificate?.canTrust == true && url.map { pendingCertificate?.certificate.matches($0) == true } == true
        forgetCertificate.isEnabled = !testing && active != nil
        certificateStatus.isHidden = active == nil && pendingCertificate == nil
        certificateControls.isHidden = certificateStatus.isHidden
        davStatus.isHidden = davStatus.stringValue.isEmpty; needsLayout = true
    }
    @objc private func trustServerCertificate() {
        guard !testing, let issue = pendingCertificate, issue.canTrust,
              let settings = try? davSettings(), let url = try? settings.directory(), issue.certificate.matches(url),
              WebDAVCertificateDialog.confirm(issue) else { return }
        trustedCertificate = issue.certificate; pendingCertificate = nil; davChanged = true
        updateCertificateStatus(); testConnection()
    }
    @objc private func forgetServerCertificate() {
        trustedCertificate = nil; pendingCertificate = nil; davChanged = true
        davStatus.stringValue = "已移除待保存的证书信任；点击“应用”后恢复系统校验。"
        updateCertificateStatus()
    }
    @objc private func testConnection() {
        guard !testing else { return }
        do {
            _ = try ensureMaster(); let settings = try davSettings(), client = try WebDAVClient(settings)
            testing = true; pendingCertificate = nil; davStatus.stringValue = "正在测试…"; updateCertificateStatus()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try client.probe() }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.testing = false
                    // Editing/closing a settings draft must never trust a response
                    // for an earlier endpoint or accidentally persist it.
                    guard self.window != nil, self.selectedMethod == .webDAV, self.address.stringValue == settings.address,
                          self.username.stringValue == settings.username, self.password.stringValue == settings.password else {
                        self.davStatus.stringValue = "连接信息已更改，请重新测试。"
                        self.updateCertificateStatus(); return
                    }
                    self.workspace?.windowCoordinator?.webDAV.diagnostics.record(.connectionTest, backend: .webDAV, manual: true, error: { if case .failure(let error) = result { return error }; return nil }())
                    switch result {
                    case .success: self.davStatus.stringValue = "连接正常；可点击“应用”保存。实际写入仍会校验结果。"
                    case .failure(let error): self.davStatus.stringValue = error.localizedDescription; self.pendingCertificate = error as? WebDAVCertificateIssue
                    }
                    self.updateCertificateStatus()
                }
            }
        } catch { davStatus.stringValue = error.localizedDescription; updateCertificateStatus() }
    }
    private func selectedDirectory(master: String) throws -> StorageLocation.Pending? {
        guard selectedMethod == .directory else { return nil }
        guard let directoryPath else { throw ModelError.invalid("请选择 iCloud / 自定义文件夹。") }
        let url = URL(fileURLWithPath: directoryPath)
        if try location.syncDirectory()?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() { return nil }
        // SharedDataFile detects undownloaded iCloud placeholders; never mistake them for an empty folder.
        let mode: StorageLocation.Mode = try SharedDataFile.readIfPresent(url.appendingPathComponent("configuration.json")) == nil ? .migrate : .existing
        let choice = StorageLocation.Pending(path: url.path, mode: mode)
        try location.validate(choice, master: master); return choice
    }
    func validateSelection() throws {
        guard changed || davChanged else { return }
        if let loadError { throw ModelError.invalid(loadError) }
        if selectedMethod != .off {
            let master = try ensureMaster()
            _ = try selectedDirectory(master: master)
            if selectedMethod == .webDAV { _ = try davSettings() }
        }
        guard workspace?.windowCoordinator?.webDAV.busy != true else { throw ModelError.invalid("同步正在运行，请稍后应用。") }
        for url in settingsFiles where try SharedDataFile.readIfPresent(url) != originalSettings[url.path] { throw ModelError.invalid("另一个窗口已修改同步设置，请重新打开设置。") }
    }
    func applySelection() throws {
        guard changed || davChanged, let workspace, let windows = workspace.windowCoordinator else { return }
        try validateSelection()
        let protected = selectedMethod != .off
        let master = protected ? try master() : (PasswordVault.shared.cachedMaster ?? "")
        let choice = protected ? try selectedDirectory(master: master) : nil
        let dav = selectedMethod == .webDAV ? try davSettings() : nil
        if protected {
            let old = workspace.store.requiresMasterProtection, oldKey = workspace.store.masterPassword
            workspace.store.requiresMasterProtection = true; workspace.store.masterPassword = master
            guard workspace.saveConfiguration(workspace.configuration) else { workspace.store.requiresMasterProtection = old; workspace.store.masterPassword = oldKey; throw ModelError.invalid("无法保存加密配置，未更改同步。") }
        }
        // Roll back local connection settings if any step fails. No remote operation runs in this transaction.
        var files = settingsFiles + [current.appendingPathComponent("webdav-baseline.json")]
        if let choice { files.append(location.baselineURL(for: URL(fileURLWithPath: choice.path))) }
        let before = try files.map { ($0, try SharedDataFile.readIfPresent($0)) }
        windows.webDAV.cancel()
        do {
            if selectedMethod != .directory { try location.disableSync() }
            else if try location.pending() != nil { try location.schedule(nil) }
            if selectedMethod != .webDAV, windows.webDAV.enabled { try windows.webDAV.configure(nil, master: master) }
            if let choice { try location.activateReplica(choice, master: master) }
            if selectedMethod == .webDAV { try windows.webDAV.configure(dav, master: master) }
            workspace.store.requiresMasterProtection = protected
        } catch {
            windows.webDAV.cancel()
            do {
                for (url, data) in before {
                    if let data { try PrivateFile.write(data, to: url) }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                }
            } catch { throw ModelError.invalid("设置未完整保存，回退时遇到错误；请重新打开设置检查，远端数据未修改。") }
            workspace.store.requiresMasterProtection = windows.webDAV.syncEnabled
            windows.webDAV.directoryConfigurationChanged(); windows.webDAV.schedule()
            throw error
        }
        windows.webDAV.directoryConfigurationChanged(); windows.webDAV.schedule()
        if windows.webDAV.syncEnabled { windows.webDAV.queueManualSync() }
        changed = false; davChanged = false; loadSettings(); updateStatus()
    }
}
extension StorageSettingsView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { davChanged = true; pendingCertificate = nil; updateCertificateStatus() }
}
