// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class FileTableView: NSTableView {
    var context: ((Int) -> NSMenu?)?
    var onDrop: (([URL], Int) -> Void)?
    var canDrop: (() -> Bool)?
    override func menu(for event: NSEvent) -> NSMenu? { context?(row(at: convert(event.locationInWindow, from: nil))) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canDrop?() == true && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard canDrop?() == true, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onDrop?(urls, row(at: convert(sender.draggingLocation, from: nil))); return true
    }
}
final class RemoteFileSession: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private weak var workspace: WorkspaceController?
    private let table = FileTableView(), path = NSTextField(string: "."), filter = NSSearchField()
    private let status = NSTextField(labelWithString: "选择连接以浏览远程文件。"), progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消传输", target: nil, action: nil)
    private let transferMode = NSPopUpButton()
    let transferHistory = FileTransferHistory()
    private lazy var historyView = FileTransferHistoryView(history: transferHistory)
    private let historyButton = NSButton(title: "传输记录（0）", target: nil, action: nil)
    private let historyHost = NSView()
    private var historyHeight: NSLayoutConstraint!
    private var historyVisible = false
    private var resumeJobs = [UUID: ResumableFileTransfer]()
    private var pendingResume: UUID?
    private let rateControl = NSPopUpButton()
    private(set) var transferRateLimit = 0
    private let ratePresets = [0, 128*1024, 512*1024, 1024*1024, 5*1024*1024, 10*1024*1024]
    private var backend: RemoteFileBackend?
    private var scp: SCPTransfer?
    private var sshProfile: SessionProfile?
    private var launchPassword: String?
    private var sharedLease: SSHConnectionLease?
    var connectionGroup: SSHConnectionGroup? { sharedLease?.group }
    private var displayIP: String?
    private var identityID = UUID()
    private var entries = [RemoteFileEntry](), visibleEntries = [RemoteFileEntry]()
    private(set) var directory = "."
    private(set) var connected = false
    private var busy = false
    private(set) var closed = false
    private(set) var profile: SessionProfile?
    let id = UUID()
    var onStateChanged: (() -> Void)?
    var onChooseConnection: (() -> Void)?
    private let backendFactory: ((SessionProfile) throws -> RemoteFileBackend)?
    var window: NSWindow? { view.window }
    var tabTitle: String { profile == nil ? "新文件会话" : (displayIP ?? "IP 待识别") }
    var filterText: String { get { filter.stringValue } set { filter.stringValue = newValue; filterRows() } }
    var listedNames: [String] { visibleEntries.map(\.name) }
    var hasActiveOperation: Bool { busy }
    private let worker = DispatchQueue(label: "OShell.file-operations", qos: .userInitiated)
    private var operationID = UUID()
    private var pendingUploads = [URL]()
    init(workspace: WorkspaceController, backendFactory: ((SessionProfile) throws -> RemoteFileBackend)? = nil) {
        self.workspace = workspace; self.backendFactory = backendFactory
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 560)); build()
    }
    func reassignWorkspace(_ workspace: WorkspaceController) { self.workspace = workspace }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var selected: [RemoteFileEntry] { table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil } }
    private func build() {
        let content = view
        transferMode.addItems(withTitles: ["SFTP 传输", "SCP 兼容传输"]); transferMode.toolTip = "目录浏览使用 SFTP；SCP 模式使用系统 scp -O。"
        let top = NSStackView(views: [operatorButton("新会话…", target: self, action: #selector(chooseConnection)), operatorButton("重连", target: self, action: #selector(reconnect)), operatorButton("上一级", target: self, action: #selector(up)), path, operatorButton("转到", target: self, action: #selector(go)), operatorButton("刷新", target: self, action: #selector(refresh))]); top.spacing = 8
        path.target = self; path.action = #selector(go); path.setContentHuggingPriority(.defaultLow, for: .horizontal); path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filter.placeholderString = "筛选当前目录"; filter.delegate = self
        let tools = NSStackView(views: [operatorButton("上传…", target: self, action: #selector(chooseUpload)), operatorButton("下载…", target: self, action: #selector(downloadSelected)), operatorButton("SCP…", target: self, action: #selector(standaloneSCP)), transferMode, NSView(), filter]); tools.spacing = 8
        filter.widthAnchor.constraint(equalToConstant: 220).isActive = true
        for (id, title, width) in [("name", "名称", 250.0), ("type", "类型", 65.0), ("size", "大小", 85.0), ("permissions", "权限", 165.0), ("owner", "所属用户", 85.0), ("group", "所属组", 85.0), ("modified", "修改时间", 170.0)] { let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width; c.minWidth = id == "name" ? 140 : 60; table.addTableColumn(c) }
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 3, height: 2)
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openEntry); table.allowsMultipleSelection = true; table.rowHeight = 28; table.usesAlternatingRowBackgroundColors = true
        table.registerForDraggedTypes([.fileURL]); table.canDrop = { [weak self] in self?.connected == true && self?.busy == false }
        table.onDrop = { [weak self] urls, row in
            guard let self else { return }; let destination = self.visibleEntries.indices.contains(row) && self.visibleEntries[row].directory ? RemotePath.join(self.directory, self.visibleEntries[row].name) : self.directory
            self.upload(urls, to: destination)
        }
        table.context = { [weak self] row in self?.menu(for: row) }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        let hint = NSTextField(labelWithString: "拖入文件或文件夹上传；右键下载、重命名、删除。重名传输默认自动编号。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.lineBreakMode = .byTruncatingMiddle; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar; progress.isIndeterminate = true; progress.isDisplayedWhenStopped = false; progress.widthAnchor.constraint(equalToConstant: 160).isActive = true
        cancelButton.bezelStyle = .rounded; cancelButton.target = self; cancelButton.action = #selector(cancelFileOperation); cancelButton.isEnabled = false
        rateControl.identifier = .init("files.rateLimit")
        rateControl.setAccessibilityLabel("传输限速")
        rateControl.toolTip = "当前文件标签的上传 / 下载速率上限。SFTP、FTP 可在传输中实时调整；SCP 兼容模式在下次传输生效。0 表示不限速，速率按文件内容计算，缓冲可能造成短时波动。"
        rateControl.target = self; rateControl.action = #selector(changeTransferRate)
        rateControl.widthAnchor.constraint(equalToConstant: 174).isActive = true
        refreshRateControl()
        historyButton.bezelStyle = .rounded; historyButton.target = self; historyButton.action = #selector(toggleHistory)
        historyButton.identifier = .init("files.transferHistory.toggle")
        historyView.translatesAutoresizingMaskIntoConstraints = false; historyHost.addSubview(historyView)
        NSLayoutConstraint.activate([historyView.topAnchor.constraint(equalTo: historyHost.topAnchor), historyView.leadingAnchor.constraint(equalTo: historyHost.leadingAnchor), historyView.trailingAnchor.constraint(equalTo: historyHost.trailingAnchor), historyView.heightAnchor.constraint(equalToConstant: 180)])
        historyHeight = historyHost.heightAnchor.constraint(equalToConstant: 0); historyHost.isHidden = true
        transferHistory.observe { [weak self] in
            guard let self, !self.closed else { return }
            let retained = Set(self.transferHistory.snapshot.map(\.id)); self.resumeJobs = self.resumeJobs.filter { retained.contains($0.key) }
            self.historyButton.title = "传输记录（\(self.transferHistory.snapshot.count)）"; self.historyView.reload()
        }
        historyView.canPause = { [weak self] in self?.pausableRecord != nil }
        historyView.canResume = { [weak self] in self?.canResumeTransfer($0) == true }
        historyView.onPause = { [weak self] in self?.pauseTransfer() }
        historyView.onResume = { [weak self] in self?.resumeTransfer($0) }
        let bottom = NSStackView(views: [historyButton, status, NSView(), rateControl, progress, cancelButton]); bottom.spacing = 8
        [top, tools, scroll, historyHost, hint, bottom].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), tools.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10), tools.leadingAnchor.constraint(equalTo: top.leadingAnchor), tools.trailingAnchor.constraint(equalTo: top.trailingAnchor), scroll.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: top.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: top.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: historyHost.topAnchor, constant: -8), historyHost.leadingAnchor.constraint(equalTo: top.leadingAnchor), historyHost.trailingAnchor.constraint(equalTo: top.trailingAnchor), historyHost.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -4), historyHeight, hint.leadingAnchor.constraint(equalTo: top.leadingAnchor), hint.trailingAnchor.constraint(lessThanOrEqualTo: top.trailingAnchor), hint.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8), bottom.leadingAnchor.constraint(equalTo: top.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: top.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
    }
    @objc func toggleHistory() { showHistory(!historyVisible) }
    private func showHistory(_ visible: Bool) { historyVisible = visible; historyHost.isHidden = !visible; historyHeight.constant = visible ? 180 : 0; historyView.updateActions() }
    private var historyTransport: String { profile?.kind == .ftp ? "FTP" : (transferMode.indexOfSelectedItem == 1 ? "SCP" : "SFTP") }
    func connect(_ profile: SessionProfile, directory: String? = nil, uploading: [URL] = [], password: String? = nil, connectionGroup: SSHConnectionGroup? = nil) {
        guard let workspace, !busy, !closed, profile.kind != .local else { return }
        var profile = profile
        do {
            if connectionGroup == nil { profile = try workspace.configuration.resolvingProxy(profile) }
        } catch { reportError(error); return }
        let lease: SSHConnectionLease?
        do { lease = try connectionGroup.map { try SSHConnectionLease(group: $0, profile: profile) } }
        catch { reportError(error); return }
        if let old = self.profile, old.id != profile.id || old.host != profile.host || old.port != profile.port || old.username != profile.username || old.kind != profile.kind { transferHistory.reset(); resumeJobs.removeAll(); pendingResume = nil }
        self.profile = profile; pendingUploads = uploading; launchPassword = connectionGroup == nil ? password : nil
        identityID = UUID(); let identity = identityID
        displayIP = FileSessionAddress.literal(profile.host)
        if displayIP == nil {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let address = FileSessionAddress.resolve(profile)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.identityID == identity else { return }
                    self.displayIP = address; self.onStateChanged?()
                }
            }
        }
        let destination = directory ?? profile.initialDirectory
        onStateChanged?()
        do {
            backend?.cancel(); backend = nil; connected = false; sharedLease = lease
            sshProfile = profile.kind.usesSSH ? profile : nil
            transferMode.removeAllItems(); transferMode.addItems(withTitles: profile.kind == .ftp ? ["FTP 传输"] : ["SFTP 传输", "SCP 兼容传输"])
            transferMode.isEnabled = profile.kind.usesSSH
            if let backendFactory { backend = try backendFactory(profile); connectBackend(destination); return }
            if profile.kind.usesSSH {
                backend = try SFTPBackend(profile: profile, knownHosts: workspace.knownHostsURL, oneTimePassword: launchPassword, connectionGroup: connectionGroup)
                connectBackend(destination)
            } else {
                let token = UUID(); operationID = token; busy = true; status.stringValue = "等待 FTP 认证…"; onStateChanged?()
                let finish: (String?) -> Void = { [weak self] password in
                    guard let self, !self.closed, self.operationID == token else { return }
                    self.busy = false
                    guard let password else { self.status.stringValue = "已取消 FTP 认证"; self.onStateChanged?(); return }
                    self.backend = FTPBackend(profile: profile.ftpProfile, password: password); self.connectBackend(destination)
                }
                if let password { finish(password) }
                else if profile.encryptedPassword != nil {
                    PasswordVault.shared.decrypt(profile, resolve: false) { [weak self] result in
                        switch result {
                        case .success(let value): finish(value.0)
                        case .failure(let error): finish(nil); if self?.closed == false { self?.reportError(error) }
                        }
                    }
                } else {
                    let alert = PopupAlert(); alert.messageText = "FTP 身份验证"; alert.informativeText = "\(profile.username)@\(profile.host):\(profile.port)"
                    alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
                    let password = PasswordEntryView(identifier: "ftp.auth.password"); password.frame = NSRect(x: 0, y: 0, width: 350, height: 26)
                    alert.accessoryView = password; alert.window.initialFirstResponder = password.secureField
                    let accepted = alert.runModal() == .alertFirstButtonReturn
                    finish(accepted ? password.stringValue : nil); password.clear()
                }
            }
        } catch { reportError(error) }
    }
    private func reportError(_ error: Error) {
        pendingResume = nil
        status.stringValue = error.localizedDescription; onStateChanged?()
        if window != nil && !closed { Dialogs.message((profile?.name ?? "文件会话") + "：" + error.localizedDescription) }
    }
    @objc private func reconnect() { guard let profile else { chooseConnection(); return }; connect(profile, directory: directory, password: launchPassword, connectionGroup: connectionGroup) }
    var transientPassword: String? { launchPassword }
    private func connectBackend(_ destination: String) {
        connected = false; guard backend != nil else { return }
        backend?.setTransferRateLimit(transferRateLimit)
        onStateChanged?()
        perform("正在连接…") { backend in
            try backend.connect(); let path = try backend.canonicalPath(destination); return (path, try backend.list(path))
        } completion: { [weak self] value in
            guard let self else { return }; self.connected = true; self.display(value)
            if let id = self.pendingResume { self.pendingResume = nil; self.runResume(id); return }
            let pending = self.pendingUploads; self.pendingUploads = []; if !pending.isEmpty { self.upload(pending, to: self.directory) }
        }
    }
    private func perform<T>(_ label: String, id: UUID = UUID(), historyBatch: UUID? = nil, operation: @escaping (RemoteFileBackend) throws -> T, completion: @escaping (T) -> Void) {
        guard !busy, !closed, let backend else { return }
        busy = true; cancelButton.isEnabled = true; status.stringValue = label; progress.isIndeterminate = true; progress.startAnimation(nil)
        let token = id; operationID = token; onStateChanged?(); historyView.updateActions()
        let history = transferHistory
        worker.async { [weak self] in
            let result = Result { try operation(backend) }
            if let historyBatch {
                switch result { case .success: history.finishBatch(historyBatch, error: nil); case .failure(let error): history.finishBatch(historyBatch, error: error) }
            }
            DispatchQueue.main.async {
                guard let self, !self.closed, self.operationID == token else { return }
                self.busy = false; self.cancelButton.isEnabled = false; self.progress.stopAnimation(nil); if historyBatch != nil { self.scp = nil }; self.onStateChanged?(); self.historyView.updateActions()
                switch result {
                case .success(let value): self.status.stringValue = "完成"; completion(value)
                case .failure(let error): self.reportError(error)
                }
            }
        }
    }
    private func rateTitle(_ rate: Int) -> String {
        if rate == 0 { return "不限速" }
        let unit = rate >= 1024*1024 ? 1048576 : 1024
        let value = rate % unit == 0 ? String(rate/unit) : String(format:"%.2f",Double(rate)/Double(unit))
        return value + (unit == 1048576 ? " MiB/s" : " KiB/s")
    }
    private func refreshRateControl() {
        rateControl.removeAllItems()
        for rate in ratePresets { rateControl.addItem(withTitle:"限速："+rateTitle(rate)); rateControl.lastItem?.tag = rate }
        rateControl.addItem(withTitle:ratePresets.contains(transferRateLimit) ? "自定义…" : "自定义："+rateTitle(transferRateLimit)); rateControl.lastItem?.tag = -1
        rateControl.selectItem(withTag:ratePresets.contains(transferRateLimit) ? transferRateLimit : -1)
    }
    func setTransferRateLimit(_ bytesPerSecond: Int) {
        transferRateLimit = min(FileTransferRateLimiter.maximum, max(0,bytesPerSecond))
        backend?.setTransferRateLimit(transferRateLimit); refreshRateControl()
        if busy && scp != nil { status.stringValue = "限速已修改，当前 SCP 仍使用启动时的上限；下次传输生效。" }
    }
    static func parseTransferRate(_ text: String, unit: Int) -> Int? {
        guard unit == 1024 || unit == 1048576, let value = Double(text.trimmingCharacters(in:.whitespacesAndNewlines)), value.isFinite, value >= 0 else { return nil }
        let bytes = value*Double(unit)
        guard bytes == 0 || (bytes >= 1024 && bytes <= Double(FileTransferRateLimiter.maximum)) else { return nil }
        return Int(bytes.rounded())
    }
    @objc private func changeTransferRate() {
        guard let selected = rateControl.selectedItem else { return }
        if selected.tag >= 0 { setTransferRateLimit(selected.tag); return }
        let alert = PopupAlert(); alert.messageText = "传输速率上限"
        alert.informativeText = "仅作用于当前文件标签。0 表示不限速；范围为 1 KiB/s–1024 MiB/s。SFTP / FTP 实时生效；SCP 下次传输生效。"
        alert.addButton(withTitle:"应用"); alert.addButton(withTitle:"取消")
        let value = NSTextField(string:String(format:"%g",Double(transferRateLimit)/1024)), unit = NSPopUpButton()
        unit.addItems(withTitles:["KiB/s","MiB/s"])
        value.identifier = .init("files.rateLimit.custom"); unit.identifier = .init("files.rateLimit.unit")
        value.widthAnchor.constraint(equalToConstant:180).isActive = true
        let row = NSStackView(views:[value,unit]); row.spacing = 8; row.frame = NSRect(x:0,y:0,width:300,height:28)
        alert.accessoryView = row; alert.window.initialFirstResponder = value
        while alert.runModal() == .alertFirstButtonReturn {
            if let rate = Self.parseTransferRate(value.stringValue,unit:unit.indexOfSelectedItem == 0 ? 1024 : 1048576) { setTransferRateLimit(rate); return }
            alert.informativeText = "请输入有效速率：0 为不限速，非零范围为 1 KiB/s–1024 MiB/s。"
        }
        refreshRateControl()
    }
    private func progressCallback(_ name: String, token: UUID, recordID: UUID? = nil) -> (UInt64, UInt64) -> Void {
        var last = DispatchTime.now().uptimeNanoseconds, previousBytes: UInt64 = 0
        let history = transferHistory
        return { [weak self] bytes, total in
            let now = DispatchTime.now().uptimeNanoseconds
            let refresh = now - last > 100_000_000 || bytes == total || bytes == 0
            if let recordID { history.progress(recordID, bytes: bytes, total: total, notify: refresh) }
            guard refresh else { return }
            let delta = bytes >= previousBytes ? bytes-previousBytes : bytes
            let speed = Double(delta) / max(0.001,Double(now-last)/1_000_000_000)
            last = now; previousBytes = bytes
            DispatchQueue.main.async {
                guard let self, !self.closed, self.operationID == token else { return }
                let done = ByteCountFormatter.string(fromByteCount:Int64(clamping:bytes),countStyle:.binary)
                let amount = total > 0 ? " / " + ByteCountFormatter.string(fromByteCount:Int64(clamping:total),countStyle:.binary) : ""
                self.status.stringValue = "\(name) · \(done)\(amount) · " + ByteCountFormatter.string(fromByteCount:Int64(min(speed,Double(Int64.max-1024))),countStyle:.binary) + "/s"
                if total > 0 { self.progress.isIndeterminate = false; self.progress.doubleValue = Double(bytes) / Double(total) * 100 }
            }
        }
    }
    private func display(_ result: (String, [RemoteFileEntry])) {
        directory = result.0; path.stringValue = result.0; entries = result.1.sorted { $0.directory == $1.directory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.directory }
        filterRows(); status.stringValue = "\(entries.count) 个项目 · \(backend?.description ?? "")"; onStateChanged?()
    }
    private func filterRows() { let query = filter.stringValue; visibleEntries = entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }; table.reloadData() }
    func controlTextDidChange(_ obj: Notification) { filterRows() }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = visibleEntries[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "name":
            let cell = tableView.makeView(withIdentifier: RemoteFileNameCell.reuseIdentifier, owner: self) as? RemoteFileNameCell ?? RemoteFileNameCell()
            cell.configure(entry)
            return cell
        case "permissions": text = entry.permissionsText
        case "owner": text = entry.owner ?? "—"
        case "group": text = entry.group ?? "—"
        case "type": text = RemoteFileKind(entry).rawValue
        case "size": text = entry.directory || entry.unknownType ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)
        default: if let modified = entry.modified { text = DateFormatter.localizedString(from: modified, dateStyle: .short, timeStyle: .short) } else { text = "—" }
        }
        let label = NSTextField(labelWithString: text)
        if tableColumn?.identifier.rawValue == "permissions" { label.font = .oshellMonospacedSystemFont(ofSize: 12, weight: .regular) }
        label.lineBreakMode = .byTruncatingMiddle; label.toolTip = text; return label
    }
    @objc private func go() { navigate(path.stringValue) }
    @objc private func up() { navigate((directory as NSString).deletingLastPathComponent.isEmpty ? "/" : (directory as NSString).deletingLastPathComponent) }
    @objc private func refresh() { navigate(directory) }
    func navigate(_ path: String) {
        guard connected else { return }
        perform("正在读取目录…") { backend in let canonical = try backend.canonicalPath(path); return (canonical, try backend.list(canonical)) } completion: { [weak self] in self?.display($0) }
    }
    @objc private func openEntry() {
        guard !busy, visibleEntries.indices.contains(table.clickedRow) else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        if let entry = selected.first, entry.directory || entry.symbolicLink || entry.unknownType { navigate(RemotePath.join(directory, entry.name)) } else { downloadSelected() }
    }
    private func menu(for row: Int) -> NSMenu {
        if visibleEntries.indices.contains(row) { if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } } else { table.deselectAll(nil) }
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ enabled: Bool) { let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self; item.isEnabled = enabled && connected && !busy }
        add("下载…", #selector(downloadSelected), !selected.isEmpty)
        add("重命名…", #selector(renameEntry), selected.count == 1)
        add("删除…", #selector(deleteEntries), !selected.isEmpty)
        menu.addItem(.separator()); add("上传…", #selector(chooseUpload), true); add("新建目录…", #selector(newDirectory), true); add("刷新", #selector(refresh), true)
        return menu
    }
    @objc private func chooseUpload() {
        guard connected, !busy else { return }
        let panel = NSOpenPanel(); panel.title = "上传到 \(directory)"; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runPopupModal() == .OK { upload(panel.urls, to: directory) }
    }
    func upload(_ urls: [URL], to destination: String) {
        guard connected, !busy, !urls.isEmpty else { return }
        let alert = PopupAlert(); alert.messageText = "上传 \(urls.count) 个项目"; alert.informativeText = "目标：\(profile?.name ?? "") · \(profile?.host ?? "") · \(destination)\n" + urls.map(\.lastPathComponent).prefix(10).joined(separator: "\n") + "\n重名自动编号；文件夹将递归上传。"
        let input = NSTextField(string: destination); input.frame = NSRect(x: 0, y: 0, width: 500, height: 26); alert.accessoryView = input; alert.addButton(withTitle: "上传"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let target = input.stringValue, useSCP = sshProfile != nil && transferMode.indexOfSelectedItem == 1
        let token = UUID(), history = transferHistory
        let records = urls.map { history.enqueue(batch: token, upload: true, transport: historyTransport, local: $0.path, remote: RemotePath.join(target, $0.lastPathComponent)) }
        showHistory(true)
        do { if useSCP, let profile = sshProfile, let workspace { scp = try SCPTransfer(profile: profile, knownHosts: workspace.knownHostsURL, oneTimePassword: launchPassword, connectionGroup: connectionGroup, rateLimit: transferRateLimit) } } catch { history.finishBatch(token, error: error); Dialogs.message(error.localizedDescription); return }
        let scp = self.scp
        perform("正在上传…", id: token, historyBatch: token) { [weak self] backend in
            var names = Set(try backend.list(target).map(\.name))
            for (index, url) in urls.enumerated() {
                let record = records[index]
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard history.start(record, directory: isDirectory) else { throw ModelError.invalid("传输已取消。") }
                guard RemotePath.safeName(url.lastPathComponent) else { throw ModelError.invalid("文件名包含不支持的字符。") }
                let name = Self.uniqueName(url.lastPathComponent, existing: names); names.insert(name)
                let remote = RemotePath.join(target, name)
                history.remoteDestination(record, remote: remote)
                if useSCP { guard let scp else { throw ModelError.invalid("SCP 连接不可用。"); }; try scp.run(local: url, remote: remote, upload: true) }
                else if let resumable = backend as? ResumableFileBackend, !isDirectory {
                    let job = ResumableFileTransfer(local: url, remote: remote, upload: true)
                    self?.registerResume(job, record: record)
                    try resumable.transfer(job, progress: self?.progressCallback(name, token: token, recordID: record) ?? { _,_ in })
                } else { try backend.upload(url, to: remote, progress: self?.progressCallback(name, token: token, recordID: record) ?? { _, _ in }) }
                history.succeed(record)
            }
            return (target, try backend.list(target))
        } completion: { [weak self] in self?.scp = nil; self?.display($0) }
    }
    @objc private func downloadSelected() {
        guard connected, !busy, !selected.isEmpty else { return }; let files = selected, parent = directory
        let panel = NSOpenPanel(); panel.title = "从 \(profile?.name ?? "") 下载保存到…"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runPopupModal() == .OK, let destination = panel.url else { return }
        download(files, from: parent, to: destination)
    }
    func download(_ files: [RemoteFileEntry], from parent: String, to destination: URL) {
        guard connected, !busy, !files.isEmpty else { return }
        let useSCP = sshProfile != nil && transferMode.indexOfSelectedItem == 1
        let token = UUID(), history = transferHistory
        let records = files.map { history.enqueue(batch: token, upload: false, transport: historyTransport, local: destination.appendingPathComponent($0.name).path, remote: RemotePath.join(parent, $0.name), directory: $0.directory) }
        showHistory(true)
        do { if useSCP, let profile = sshProfile, let workspace { scp = try SCPTransfer(profile: profile, knownHosts: workspace.knownHostsURL, oneTimePassword: launchPassword, connectionGroup: connectionGroup, rateLimit: transferRateLimit) } } catch { history.finishBatch(token, error: error); Dialogs.message(error.localizedDescription); return }
        let scp = self.scp
        perform("正在下载…", id: token, historyBatch: token) { [weak self] backend in
            var names = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
            for (index, entry) in files.enumerated() {
                let record = records[index]
                guard history.start(record) else { throw ModelError.invalid("传输已取消。") }
                guard RemotePath.safeName(entry.name) else { throw ModelError.invalid("远程文件名无效。") }
                let name = Self.uniqueName(entry.name, existing: names); names.insert(name); let local = destination.appendingPathComponent(name), remote = RemotePath.join(parent, entry.name)
                history.destination(record, local: local.path)
                if useSCP {
                    // Stage SCP in a fresh directory so it cannot overwrite an
                    // existing destination even if another process creates it.
                    let stage = destination.appendingPathComponent(".oshell-scp-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: stage) }
                    guard let scp else { throw ModelError.invalid("SCP 连接不可用。"); }; try scp.run(local: stage, remote: remote, upload: false)
                    try FileManager.default.moveItem(at: stage.appendingPathComponent(entry.name), to: local)
                } else if let resumable = backend as? ResumableFileBackend, !entry.directory && !entry.symbolicLink && !entry.unknownType {
                    let job = ResumableFileTransfer(local: local, remote: remote, upload: false)
                    self?.registerResume(job, record: record)
                    try resumable.transfer(job, progress: self?.progressCallback(name, token: token, recordID: record) ?? { _,_ in })
                } else { try backend.download(remote, to: local, progress: self?.progressCallback(name, token: token, recordID: record) ?? { _, _ in }) }
                history.succeed(record)
            }
            return files.count
        } completion: { [weak self] count in self?.scp = nil; self?.status.stringValue = "已下载 \(count) 个项目到 \(destination.path)" }
    }
    private static func uniqueName(_ name: String, existing: Set<String>) -> String { var next = name, index = 1; while existing.contains(next) { next = name + ".\(index)"; index += 1 }; return next }
    private func askName(_ title: String, initial: String) -> String? {
        let alert = PopupAlert(); alert.messageText = title; alert.informativeText = "\(profile?.name ?? "") · \(profile?.host ?? "") · \(directory)"; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 420, height: 26); alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard RemotePath.safeName(field.stringValue) else { Dialogs.message("请输入不含斜杠或控制字符的名称。"); return nil }; return field.stringValue
    }
    @objc private func newDirectory() { guard connected, !busy, let name = askName("新建远程目录", initial: "新目录") else { return }; let parent = directory; perform("正在创建目录…") { backend in try backend.mkdir(RemotePath.join(parent, name)); return (parent, try backend.list(parent)) } completion: { [weak self] in self?.display($0) } }
    @objc private func renameEntry() {
        guard connected, !busy, selected.count == 1, let entry = selected.first, let name = askName("重命名“\(entry.name)”", initial: entry.name), name != entry.name else { return }
        guard !entries.contains(where: { $0.name == name }) else { Dialogs.message("目标名称已存在。"); return }
        let parent = directory; perform("正在重命名…") { backend in try backend.rename(RemotePath.join(parent, entry.name), to: RemotePath.join(parent, name)); return (parent, try backend.list(parent)) } completion: { [weak self] in self?.display($0) }
    }
    @objc private func deleteEntries() {
        guard connected, !busy, !selected.isEmpty else { return }; let entries = selected, parent = directory
        guard Dialogs.confirm("删除 \(entries.count) 个远程项目？", text: entries.map(\.name).joined(separator: "\n") + "\n永久删除，不进入废纸篓；目录必须为空。", action: "删除") else { return }
        perform("正在删除…") { backend in for entry in entries { try backend.remove(RemotePath.join(parent, entry.name), directory: entry.directory) }; return (parent, try backend.list(parent)) } completion: { [weak self] in self?.display($0) }
    }
    private func registerResume(_ job: ResumableFileTransfer, record: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, self.transferHistory.snapshot.contains(where: { $0.id == record }) else { return }
            self.resumeJobs[record] = job; self.transferHistory.partialDestination(record, path: job.partialDescription); self.historyView.selectRecord(record)
        }
    }
    private var pausableRecord: UUID? {
        guard busy, !closed else { return nil }
        return transferHistory.snapshot.first { $0.batch == operationID && $0.state == .running && $0.total > 0 && $0.bytes < $0.total && resumeJobs[$0.id] != nil }?.id
    }
    func canResumeTransfer(_ id: UUID) -> Bool {
        !busy && !closed && resumeJobs[id] != nil && transferHistory.snapshot.contains { $0.id == id && [.paused,.failed,.cancelled].contains($0.state) }
    }
    func pauseTransfer() {
        guard pausableRecord != nil else { return }
        transferHistory.pause(operationID)
        operationID = UUID(); pendingResume = nil; backend?.cancel(); backend = nil; scp?.cancel(); scp = nil
        busy = false; connected = false; pendingUploads = []; cancelButton.isEnabled = false; progress.stopAnimation(nil)
        status.stringValue = "已暂停并保留临时文件；选中记录后点击继续。后续未开始项目请重新传输。"
        historyView.reload(); onStateChanged?()
    }
    func resumeTransfer(_ id: UUID) {
        guard canResumeTransfer(id), let profile else { return }
        pendingResume = id
        connect(profile, directory: directory, password: launchPassword, connectionGroup: connectionGroup)
        historyView.updateActions()
    }
    private func runResume(_ id: UUID) {
        guard let job = resumeJobs[id], let backend = backend as? ResumableFileBackend, !busy, !closed else { return }
        let token = UUID(), history = transferHistory
        guard history.requeue(id, batch: token) else { return }
        showHistory(true); historyView.selectRecord(id)
        perform("正在校验已传内容并续传…", id: token, historyBatch: token) { [weak self] _ in
            guard history.start(id) else { throw ModelError.invalid("续传已取消。") }
            try backend.transfer(job, progress: self?.progressCallback(job.local.lastPathComponent, token: token, recordID: id) ?? { _,_ in })
            history.succeed(id)
        } completion: { [weak self] in
            self?.status.stringValue = "续传完成"; if job.upload { self?.refresh() }
        }
    }
    @objc func cancelFileOperation() {
        let resumable = transferHistory.snapshot.contains { $0.batch == operationID && resumeJobs[$0.id] != nil }
        pendingResume = nil
        transferHistory.cancel(operationID)
        operationID = UUID(); backend?.cancel(); backend = nil; scp?.cancel(); scp = nil; busy = false; connected = false; pendingUploads = []
        cancelButton.isEnabled = false; progress.stopAnimation(nil); status.stringValue = resumable ? "已取消并保留临时片段；选中记录后可重试续传。" : "已取消并断开文件连接，部分文件可能保留；可点击重连恢复。"; onStateChanged?(); historyView.updateActions()
    }
    func shutdown() {
        guard !closed else { return }; closed = true; launchPassword = nil; identityID = UUID(); cancelFileOperation(); sharedLease = nil; onStateChanged = nil; onChooseConnection = nil; transferHistory.observe(nil); transferHistory.reset(); resumeJobs.removeAll(); historyView.dispose()
    }
    @objc private func chooseConnection() { onChooseConnection?() }
    @objc private func standaloneSCP() {
        guard !busy, let profile = sshProfile, let workspace else { Dialogs.message("请先选择一个 SSH 会话；FTP 不使用 SCP。"); return }
        let alert = PopupAlert(); alert.messageText = "SCP 文件传输"; alert.informativeText = "使用系统 scp -O，可用于没有 SFTP 子系统的 SSH 服务器。填写完整远程路径；确认后可能覆盖该目标路径。"
        alert.addButton(withTitle: "上传…"); alert.addButton(withTitle: "下载…"); alert.addButton(withTitle: "取消")
        let remote = NSTextField(string: path.stringValue); remote.frame = NSRect(x: 0, y: 0, width: 560, height: 26); alert.accessoryView = remote
        let response = alert.runModal(); guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        let uploading = response == .alertFirstButtonReturn
        let panel = NSOpenPanel(); panel.canChooseFiles = uploading; panel.canChooseDirectories = true; panel.canCreateDirectories = !uploading
        guard panel.runPopupModal() == .OK, let url = panel.url else { return }
        let token = UUID(), history = transferHistory
        let record = history.enqueue(batch: token, upload: uploading, transport: "SCP", local: url.path, remote: remote.stringValue)
        showHistory(true)
        do {
            try RemotePath.validate(remote.stringValue)
            let task = try SCPTransfer(profile: profile, knownHosts: workspace.knownHostsURL, oneTimePassword: launchPassword, connectionGroup: connectionGroup, rateLimit: transferRateLimit); scp = task
            let remotePath = remote.stringValue; operationID = token; busy = true; cancelButton.isEnabled = true; progress.isIndeterminate = true; progress.startAnimation(nil); status.stringValue = "SCP 传输中…"; onStateChanged?()
            worker.async { [weak self] in
                let result = Result {
                    guard history.start(record, directory: uploading && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)) else { throw ModelError.invalid("传输已取消。") }
                    if uploading { try task.run(local: url, remote: remotePath, upload: true) }
                    else {
                        let name = (remotePath as NSString).lastPathComponent
                        guard RemotePath.safeName(name) else { throw ModelError.invalid("请填写完整的远程文件或目录路径。"); }
                        let stage = url.appendingPathComponent(".oshell-scp-" + UUID().uuidString)
                        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                        defer { try? FileManager.default.removeItem(at: stage) }
                        try task.run(local: stage, remote: remotePath, upload: false)
                        let existing = Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
                        let local = url.appendingPathComponent(Self.uniqueName(name, existing: existing))
                        history.destination(record, local: local.path)
                        try FileManager.default.moveItem(at: stage.appendingPathComponent(name), to: local)
                    }
                }
                switch result { case .success: history.succeed(record); case .failure(let error): history.finishBatch(token, error: error) }
                DispatchQueue.main.async {
                    guard let self, !self.closed, self.operationID == token else { return }; self.busy = false; self.cancelButton.isEnabled = false; self.progress.stopAnimation(nil); self.scp = nil; self.onStateChanged?()
                    switch result { case .success: self.status.stringValue = "SCP 传输完成"; if self.connected { self.refresh() }; case .failure(let error): self.reportError(error) }
                }
            }
        } catch { history.finishBatch(token, error: error); Dialogs.message(error.localizedDescription) }
    }
}
