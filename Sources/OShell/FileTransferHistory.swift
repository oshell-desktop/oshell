// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Per-file-tab, memory-only transfer journal. Workers never mutate AppKit views.
final class FileTransferHistory {
    enum State: String { case queued = "等待", running = "传输中", paused = "已暂停", succeeded = "成功", failed = "失败", cancelled = "已取消", skipped = "未执行"
        var finished: Bool { self != .queued && self != .running && self != .paused }
    }
    struct Record {
        let id: UUID, upload: Bool, transport: String, created: Date
        var batch: UUID
        var local: String, remote: String, directory: Bool
        var state = State.queued, started: Date?, ended: Date?, bytes: UInt64 = 0, total: UInt64 = 0, error = "", partialPath = ""
        var name: String { ((upload ? local : remote) as NSString).lastPathComponent }
        var amount: String {
            if directory { return "目录（含子项）" }
            if total > 0 { return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file) }
            return bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) : "—"
        }
        var detail: String {
            func date(_ value: Date) -> String { DateFormatter.localizedString(from: value, dateStyle: .medium, timeStyle: .medium) }
            return "\(upload ? "上传" : "下载") · \(transport) · \(state.rawValue)\n本地：\(local)\n远程：\(remote)\n创建：\(date(created))" + (started.map { "\n开始：" + date($0) } ?? "") + (ended.map { "\n结束：" + date($0) } ?? "") + "\n传输量：\(amount)" + (partialPath.isEmpty ? "" : "\n临时片段（成功后移除）：\(partialPath)") + (error.isEmpty ? "" : "\n说明：\(error)")
        }
    }
    private let lock = NSLock()
    private var records = [Record](), observer: (() -> Void)?, notificationPending = false
    let limit: Int
    init(limit: Int = 500) { self.limit = max(1, limit) }
    var snapshot: [Record] { lock.lock(); defer { lock.unlock() }; return records }
    func observe(_ callback: (() -> Void)?) { lock.lock(); observer = callback; lock.unlock() }
    // Only transitions into a finished state can exceed the completed-history limit.
    private func change(notify: Bool = true, trim: Bool = false, _ body: (inout [Record]) -> Void) {
        lock.lock(); body(&records)
        if trim {
            var excess = records.reduce(0) { $0 + ($1.state.finished ? 1 : 0) } - limit
            if excess > 0 {
                records.removeAll { record in if excess > 0 && record.state.finished { excess -= 1; return true }; return false }
            }
        }
        let schedule = notify && !notificationPending
        if schedule { notificationPending = true }; lock.unlock()
        if schedule { DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.lock.lock(); self.notificationPending = false; let callback = self.observer; self.lock.unlock(); callback?()
        } }
    }
    @discardableResult func enqueue(batch: UUID, upload: Bool, transport: String, local: String, remote: String, directory: Bool = false) -> UUID {
        let id = UUID(); change { $0.append(Record(id: id, upload: upload, transport: transport, created: Date(), batch: batch, local: local, remote: remote, directory: directory)) }; return id
    }
    @discardableResult func start(_ id: UUID, local: String? = nil, remote: String? = nil, directory: Bool? = nil) -> Bool {
        var accepted = false
        change { records in
            guard let i = records.firstIndex(where: { $0.id == id && $0.state == .queued }) else { return }
            records[i].state = .running; records[i].started = Date()
            if let local { records[i].local = local }; if let remote { records[i].remote = remote }; if let directory { records[i].directory = directory }
            accepted = true
        }; return accepted
    }
    func progress(_ id: UUID, bytes: UInt64, total: UInt64, notify: Bool = true) {
        change(notify: notify, trim: false) { records in
            guard let i = records.firstIndex(where: { $0.id == id && $0.state == .running }), !records[i].directory else { return }
            records[i].bytes = bytes; records[i].total = total
        }
    }
    func partialDestination(_ id: UUID, path: String) {
        change { records in guard let i = records.firstIndex(where: { $0.id == id }) else { return }; records[i].partialPath = path }
    }
    func remoteDestination(_ id: UUID, remote: String) {
        change { records in guard let i = records.firstIndex(where: { $0.id == id && $0.state == .running }) else { return }; records[i].remote = remote }
    }
    func destination(_ id: UUID, local: String) {
        change { records in guard let i = records.firstIndex(where: { $0.id == id && $0.state == .running }) else { return }; records[i].local = local }
    }
    func succeed(_ id: UUID) {
        change(trim: true) { records in
            guard let i = records.firstIndex(where: { $0.id == id && $0.state == .running }) else { return }
            records[i].state = .succeeded; records[i].ended = Date()
        }
    }
    func finishBatch(_ batch: UUID, error: Error?) {
        change(trim: true) { records in
            var preparationFailed = error != nil && !records.contains { $0.batch == batch && $0.started != nil }
            for i in records.indices where records[i].batch == batch && [State.queued, .running].contains(records[i].state) {
                records[i].state = records[i].state == .running || preparationFailed ? .failed : .skipped
                preparationFailed = false
                records[i].error = String((error?.localizedDescription ?? "本批次已结束，该项目未执行。").prefix(2000)); records[i].ended = Date()
            }
        }
    }
    func cancel(_ batch: UUID) {
        change(trim: true) { records in for i in records.indices where records[i].batch == batch && [State.queued, .running].contains(records[i].state) {
            records[i].state = .cancelled; records[i].ended = Date(); records[i].error = "用户取消；已传输的部分内容可能保留。"
        } }
    }
    func pause(_ batch: UUID) {
        change(trim: true) { records in for i in records.indices where records[i].batch == batch {
            if records[i].state == .running { records[i].state = .paused; records[i].error = "已保留临时文件；选中记录后点击继续。" }
            else if records[i].state == .queued { records[i].state = .skipped; records[i].ended = Date(); records[i].error = "本批次已暂停，此项目尚未开始，请重新选择传输。" }
        } }
    }
    @discardableResult func requeue(_ id: UUID, batch: UUID) -> Bool {
        var accepted = false
        change { records in
            guard let i = records.firstIndex(where: { $0.id == id && [State.paused, .failed, .cancelled].contains($0.state) }) else { return }
            records[i].batch = batch; records[i].state = .queued; records[i].ended = nil; records[i].error = ""; accepted = true
        }; return accepted
    }
    func clearCompleted() { change { $0.removeAll { $0.state.finished } } }
    func reset() { change { $0.removeAll() } }
}

final class FileTransferHistoryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let history: FileTransferHistory
    let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    let continueButton = NSButton(title: "继续", target: nil, action: nil)
    let retryButton = NSButton(title: "重试", target: nil, action: nil)
    var canPause: (() -> Bool)?, canResume: ((UUID) -> Bool)?, onPause: (() -> Void)?, onResume: ((UUID) -> Void)?
    private var rows = [FileTransferHistory.Record]()
    private let hint = NSTextField(labelWithString: "当前标签的传输记录；双击查看路径和详情。")
    init(history: FileTransferHistory) {
        self.history = history; super.init(frame: .zero)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let clear = NSButton(title: "清空已结束", target: self, action: #selector(clearCompleted)); clear.bezelStyle = .rounded
        for (button, action, identifier) in [(pauseButton, #selector(pauseTransfer), "pause"), (continueButton, #selector(resumeTransfer), "continue"), (retryButton, #selector(resumeTransfer), "retry")] {
            button.target = self; button.action = action; button.bezelStyle = .rounded; button.identifier = .init("files.transferHistory." + identifier)
        }
        pauseButton.toolTip = "暂停当前 SFTP 普通文件；本批次后续项目停止执行。"
        continueButton.toolTip = "自动重连，校验片段后从断点继续；仅支持当前标签的 SFTP 普通文件。"
        retryButton.toolTip = "校验后重试续传；不会覆盖已有目标文件。"
        let header = NSStackView(views: [hint, NSView(), pauseButton, continueButton, retryButton, clear]); header.spacing = 6
        hint.lineBreakMode = .byTruncatingTail; hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (id, title, width) in [("time","时间",100.0),("direction","方向",50.0),("name","文件 / 目录",230.0),("state","状态",75.0),("amount","传输量",160.0),("protocol","方式",65.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.dataSource = self; table.delegate = self; table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true; table.target = self; table.doubleAction = #selector(showDetails)
        table.identifier = .init("files.transferHistory"); table.setAccessibilityLabel("当前连接上传下载记录")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        for v in [header, scroll] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: topAnchor),header.leadingAnchor.constraint(equalTo: leadingAnchor),header.trailingAnchor.constraint(equalTo: trailingAnchor),header.heightAnchor.constraint(equalToConstant:26),scroll.topAnchor.constraint(equalTo: header.bottomAnchor,constant:4),scroll.leadingAnchor.constraint(equalTo: leadingAnchor),scroll.trailingAnchor.constraint(equalTo: trailingAnchor),scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reload() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        rows = Array(history.snapshot.reversed()); table.reloadData()
        if let selected, let i = rows.firstIndex(where: { $0.id == selected }) { table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
        hint.stringValue = rows.isEmpty ? "暂无传输记录" : "\(rows.count) 条 · SFTP 文件可续传"
        updateActions()
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    func updateActions() {
        pauseButton.isEnabled = canPause?() == true
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
        let available = selected.map { canResume?($0.id) == true } ?? false
        continueButton.isEnabled = available && selected?.state == .paused
        retryButton.isEnabled = available && (selected?.state == .failed || selected?.state == .cancelled)
        hint.toolTip = "SFTP 普通文件支持暂停和续传；目录、FTP、SCP 暂不支持。关闭标签后续传记录清除，临时文件保留。"
    }
    func selectRecord(_ id: UUID) { reload(); if let row = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } }
    @objc private func pauseTransfer() { onPause?() }
    @objc private func resumeTransfer() { guard rows.indices.contains(table.selectedRow) else { return }; onResume?(rows[table.selectedRow].id) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let record = rows[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "time": text = DateFormatter.localizedString(from: record.created, dateStyle: .none, timeStyle: .medium)
        case "direction": text = record.upload ? "↑ 上传" : "↓ 下载"
        case "name": text = record.name
        case "state": text = record.state.rawValue
        case "amount": text = record.amount
        default: text = record.transport
        }
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 11); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = record.detail
        if tableColumn?.identifier.rawValue == "state" { label.textColor = record.state == .failed ? .systemRed : (record.state == .succeeded ? .systemGreen : .labelColor) }
        return label
    }
    @objc private func clearCompleted() { history.clearCompleted() }
    @objc private func showDetails() {
        guard rows.indices.contains(table.clickedRow) else { return }
        let alert = PopupAlert(); alert.messageText = "传输详情"; alert.informativeText = "当前文件标签的传输记录，可选择并复制下面的内容。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 240)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .systemFont(ofSize: 12); text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; text.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        text.string = rows[table.clickedRow].detail; scroll.documentView = text; alert.accessoryView = scroll; alert.runModal()
    }
    func dispose() { table.delegate = nil; table.dataSource = nil; canPause = nil; canResume = nil; onPause = nil; onResume = nil }
}
