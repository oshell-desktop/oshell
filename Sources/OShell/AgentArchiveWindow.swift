// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import SwiftTerm
import OShellCore

/// The replay view has no LocalProcess, PTY or connection reference. All terminal side effects terminate here.
final class AgentReplayDelegate: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Eight records maximum in flight. Reader cancellation also releases a producer waiting for the UI.
private final class AgentReplayStream: @unchecked Sendable {
    private let lock = NSCondition()
    private var events = [AgentAuditEvent](), cancelled = false
    private(set) var finished = false
    private(set) var failure: String?
    init(url: URL, root: URL, queue: DispatchQueue) {
        queue.async { [self] in
            lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { return }
            do {
                let key = try AgentAudit.key(directory: root, create: false)
                let sealed = try AgentAudit.read(url: url, key: key) { event in
                    lock.lock(); defer { lock.unlock() }
                    while events.count >= 8 && !cancelled { lock.wait() }
                    if cancelled { return false }; events.append(event); return true
                }
                lock.lock(); if !cancelled && !sealed { failure = "记录未封口：异常退出、仍在记录或尾部缺失，不能视为完整记录。" }; lock.unlock()
            } catch { lock.lock(); failure = "记录损坏或读取失败：" + error.localizedDescription; lock.unlock() }
            lock.lock(); finished = true; lock.unlock()
        }
    }
    func peek() -> AgentAuditEvent? { lock.lock(); defer { lock.unlock() }; return events.first }
    func pop() -> AgentAuditEvent? {
        lock.lock(); guard !events.isEmpty else { lock.unlock(); return nil }; let value = events.removeFirst(); lock.signal(); lock.unlock(); return value
    }
    func state() -> (Bool, String?) { lock.lock(); defer { lock.unlock() }; return (finished && events.isEmpty, failure) }
    func cancel() { lock.lock(); cancelled = true; events.removeAll(); lock.broadcast(); lock.unlock() }
}

final class AgentArchiveWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onClose: (() -> Void)?
    private let replayQueue = DispatchQueue(label: "OShell.agent.replay", qos: .utility, autoreleaseFrequency: .workItem)
    private let workQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "OShell.agent.archive"; queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility; return queue
    }()
    private var timelineWork: BlockOperation?, searchWork: BlockOperation?, exportWork: BlockOperation?
    private struct Item { let url: URL, title: String, date: Date, taskIndex: String }
    private let table = NSTableView(), filter = NSSearchField(), search = NSSearchField()
    private let status = NSTextField(wrappingLabelWithString: "存档长期保留，仅手动删除。"), slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let speed = NSPopUpButton(), idle = NSButton(checkboxWithTitle: "跳过空闲", target: nil, action: nil)
    private let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500), options: TerminalOptions(scrollback: 2000, enableSixelReported: false, kittyImageCacheLimitBytes: 0))
    private let replayDelegate = AgentReplayDelegate()
    private var items = [Item](), visible = [Item](), stream: AgentReplayStream?, selected: URL?
    private var timer: Timer?, paused = true, start: Date?, end: Date?, clock: TimeInterval = 0, lastTick: TimeInterval = 0, seekTarget: TimeInterval?
    private var selectionGeneration = UUID(), scanning = false
    init() {
        let window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Agent 存档与只读回放"; window.minSize = NSSize(width: 800, height: 640); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        terminal.terminalDelegate = replayDelegate; terminal.allowMouseReporting = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); window.contentView = content; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
        filter.placeholderString = "按时间、会话、客户端或任务 ID 筛选"; filter.delegate = self
        stack.addArrangedSubview(NSStackView(views: [filter, AgentButton("刷新存档", action: { [weak self] in self?.reload() }), AgentButton("加密导出…", action: { [weak self] in self?.export() }), AgentButton("删除选定记录…", action: { [weak self] in self?.delete() })]))
        let column = NSTableColumn(identifier: .init("archive")); column.title = "时间 · 会话 · 客户端"; column.width = 960; table.addTableColumn(column); table.dataSource = self; table.delegate = self
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(list); list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        speed.addItems(withTitles: ["0.5×", "1×", "2×", "4×", "8×"]); speed.selectItem(at: 1); idle.state = .on
        slider.target = self; slider.action = #selector(seek(_:)); slider.isContinuous = false
        let controls = NSStackView(views: [AgentButton("播放 / 暂停", action: { [weak self] in self?.paused.toggle() }), speed, idle, slider]); stack.addArrangedSubview(controls); controls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(status)
        search.placeholderString = "在选定记录内搜索命令、输出或任务 ID"; search.target = self; search.action = #selector(searchRecord)
        stack.addArrangedSubview(search); search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let viewport = NSScrollView(); viewport.hasHorizontalScroller = true; viewport.hasVerticalScroller = true; viewport.documentView = terminal
        stack.addArrangedSubview(viewport); viewport.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; viewport.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); stream?.cancel(); workQueue.cancelAllOperations() }
    func windowWillClose(_ notification: Notification) {
        paused = true; timer?.invalidate(); timer = nil; stream?.cancel(); stream = nil
        selectionGeneration = UUID(); workQueue.cancelAllOperations(); onClose?()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSTextField(labelWithString: visible[row].title) }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === filter { applyFilter() } }
    private func applyFilter() { visible = items.filter { filter.stringValue.isEmpty || $0.title.localizedCaseInsensitiveContains(filter.stringValue) || $0.taskIndex.localizedCaseInsensitiveContains(filter.stringValue) }; table.reloadData() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard visible.indices.contains(table.selectedRow) else { return }
        selected = visible[table.selectedRow].url; startPlayback(); scanTimeline()
    }
    private func reload() {
        guard !scanning else { return }; scanning = true; status.stringValue = "正在读取加密存档索引…"
        let job = BlockOperation()
        job.addExecutionBlock { [weak self, weak job] in
            guard let job, !job.isCancelled else { return }
            do {
                let root = AgentPrivateStore.root, directory = root.appendingPathComponent("archives")
                guard FileManager.default.fileExists(atPath: directory.path) else { DispatchQueue.main.async { self?.scanning = false; self?.status.stringValue = "暂无存档。" }; return }
                let key = try AgentAudit.key(directory: root, create: false)
                let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "oshell-audit" }
                var entries = [Item](), size: Int64 = 0
                let formatter = ISO8601DateFormatter()
                for url in urls {
                    if job.isCancelled { return }
                    size += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    do {
                        let fields = try AgentAudit.index(url: url, master: key)
                        let date = formatter.date(from: fields["date"]?.string ?? "") ?? .distantPast
                        entries.append(Item(url: url, title: formatter.string(from: date) + " · " + (fields["title"]?.string ?? "会话") + " · " + (fields["client_name"]?.string ?? "客户端"), date: date, taskIndex: String(decoding: try JSONEncoder().encode(fields["tasks"]), as: UTF8.self)))
                    } catch { entries.append(Item(url: url, title: "损坏 / 无法解密 · " + url.lastPathComponent, date: .distantPast, taskIndex: "")) }
                }
                let result = entries.sorted { $0.date > $1.date }
                DispatchQueue.main.async { guard !job.isCancelled else { return }; self?.items = result; self?.scanning = false; self?.applyFilter(); self?.status.stringValue = "\(result.count) 份记录 · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) + (size >= 10_000_000_000 ? " · 容量提醒：超过 10 GB，可手动导出并清理。" : " · 不自动清理。") }
            } catch { DispatchQueue.main.async { self?.scanning = false; self?.status.stringValue = error.localizedDescription } }
        }
        workQueue.addOperation(job)
    }
    private func startPlayback(seek: TimeInterval? = nil) {
        stream?.cancel(); guard let selected else { return }
        stream = AgentReplayStream(url: selected, root: AgentPrivateStore.root, queue: replayQueue)
        terminal.feed(text: "\u{1b}c"); start = nil; clock = 0; lastTick = ProcessInfo.processInfo.systemUptime; seekTarget = seek; paused = seek != nil
    }
    private func scanTimeline() {
        timelineWork?.cancel(); searchWork?.cancel()
        guard let selected else { return }; let generation = UUID(); selectionGeneration = generation; slider.isEnabled = false
        status.stringValue = "正在验证记录完整性…"
        let job = BlockOperation(); timelineWork = job
        job.addExecutionBlock { [weak self, weak job] in
            guard let job, !job.isCancelled else { return }
            do {
                let key = try AgentAudit.key(directory: AgentPrivateStore.root, create: false)
                var first: Date?, last: Date?
                let sealed = try AgentAudit.read(url: selected, key: key) { event in if first == nil { first = event.time }; last = event.time; return !job.isCancelled }
                DispatchQueue.main.async {
                    guard !job.isCancelled, let self, self.selectionGeneration == generation else { return }
                    self.end = last; self.slider.maxValue = max(1, (last ?? Date()).timeIntervalSince(first ?? Date())); self.slider.isEnabled = true
                    self.status.stringValue = sealed ? "认证与序号验证通过。只读回放无 PTY，不执行链接、剪贴板或传输指令。" : "记录未封口，可能仍在记录或异常退出；不得视为完整存档。"
                }
            } catch { DispatchQueue.main.async { guard self?.selectionGeneration == generation else { return }; self?.status.stringValue = "记录损坏：" + error.localizedDescription } }
        }
        workQueue.addOperation(job)
    }
    @objc private func seek(_ sender: NSSlider) { startPlayback(seek: sender.doubleValue) }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime; defer { lastTick = now }
        guard let stream, !paused || seekTarget != nil else { return }
        if seekTarget == nil { clock += min(0.25, now - lastTick) * [0.5, 1, 2, 4, 8][speed.indexOfSelectedItem] }
        let deadline = now + 0.006
        while let event = stream.peek(), ProcessInfo.processInfo.systemUptime < deadline {
            if start == nil { start = event.time }
            let at = max(0, event.time.timeIntervalSince(start!))
            if let seekTarget {
                if at > seekTarget { clock = seekTarget; self.seekTarget = nil; status.stringValue = "定位完成 · \(Int(clock)) 秒"; break }
                status.stringValue = "正在顺序重建：\(Int(at)) / \(Int(seekTarget)) 秒"
            } else if at > clock {
                if idle.state == .on, at - clock > 2 { clock = at } else { break }
            }
            guard let item = stream.pop() else { break }; apply(item)
            if seekTarget == nil { slider.doubleValue = clock }
        }
        let state = stream.state()
        if state.0 { paused = true; seekTarget = nil; if let failure = state.1 { status.stringValue = failure } }
    }
    #if OSHELL_TEST_HARNESS
    func applyForTesting(_ event: AgentAuditEvent) { apply(event) }
    var replayTerminalForTesting: TerminalView { terminal }
    var workForTesting: [Operation] { workQueue.operations }
    var timerForTesting: Timer? { timer }
    func selectForTesting(_ url: URL) { selected = url; startPlayback(); scanTimeline() }
    #endif
    private func apply(_ event: AgentAuditEvent) {
        if event.kind == "baseline" || event.kind == "resize" {
            let cols = min(500, max(2, event.fields["cols"]?.number ?? 80)), rows = min(200, max(2, event.fields["rows"]?.number ?? 24))
            terminal.getTerminal().resize(cols: cols, rows: rows)
            terminal.setFrameSize(terminal.getOptimalFrameSize().size)
        }
        if event.kind == "baseline", let screen = event.fields["screen"]?.string { terminal.feed(text: screen) }
        if event.kind == "display", let bytes = event.bytes { terminal.feed(byteArray: Array(bytes)[...]) }
    }
    @objc private func searchRecord() {
        guard let selected, !search.stringValue.isEmpty else { return }
        searchWork?.cancel()
        let query = search.stringValue, generation = selectionGeneration; status.stringValue = "正在检索选定记录…"
        let job = BlockOperation(); searchWork = job
        job.addExecutionBlock { [weak self, weak job] in
            guard let job, !job.isCancelled else { return }
            do {
                let key = try AgentAudit.key(directory: AgentPrivateStore.root, create: false)
                var matches = [String](); var searcher = try AgentAuditSearch(query: query)
                try AgentAudit.read(url: selected, key: key) { event in
                    if let preview = try searcher.consume(event) {
                        matches.append("#\(event.sequence) · \(event.time) · \(event.kind)\n" + preview)
                    }
                    return matches.count < 100 && !job.isCancelled
                }
                DispatchQueue.main.async {
                    guard !job.isCancelled, let self, self.selectionGeneration == generation else { return }
                    self.status.stringValue = "搜索结果 \(matches.count) 条（最多显示 100 条）"
                    let alert = PopupAlert(); alert.messageText = "命令 / 输出 / 任务搜索"
                    let (view, _) = textEditor(matches.joined(separator: "\n\n"), editable: false); view.frame = NSRect(x: 0, y: 0, width: 700, height: 400); alert.accessoryView = view; alert.addButton(withTitle: "关闭"); alert.runModal()
                }
            } catch { DispatchQueue.main.async { self?.status.stringValue = error.localizedDescription } }
        }
        workQueue.addOperation(job)
    }
    private func active(_ url: URL) -> Bool {
        (AgentCoordinator.shared.workspaceProvider?() ?? []).flatMap(\.inputPanes).contains { $0.agentAudit?.url == url }
    }
    private func delete() {
        guard let selected else { return }
        guard !active(selected) else { Dialogs.message("请先结束此会话存档，再删除。"); return }
        guard Dialogs.confirm("删除这份存档？", text: "仅删除选中的加密记录，无法撤销。", action: "删除") else { return }
        do { timelineWork?.cancel(); searchWork?.cancel(); selectionGeneration = UUID(); stream?.cancel(); stream = nil; try FileManager.default.removeItem(at: selected); try? FileManager.default.removeItem(at: selected.appendingPathExtension("index")); self.selected = nil; reload() } catch { Dialogs.message(error.localizedDescription) }
    }
    private func export() {
        guard exportWork == nil || exportWork?.isFinished == true else { status.stringValue = "已有导出正在进行。"; return }
        guard let selected else { return }
        guard !active(selected) else { Dialogs.message("请先结束此存档，确保导出的是稳定记录。"); return }
        let alert = PopupAlert(); alert.messageText = "加密导出密码"; alert.informativeText = "至少 12 个字符；导出文件包含此记录的加密密钥封装，不包含本机主密钥。"
        let password = NSSecureTextField(); password.frame = NSRect(x: 0, y: 0, width: 350, height: 24); alert.accessoryView = password; alert.addButton(withTitle: "选择导出位置"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn, password.stringValue.count >= 12 else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = selected.deletingPathExtension().lastPathComponent + ".oshell-audit-export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let secret = password.stringValue; password.stringValue = ""; status.stringValue = "正在加密导出…"
        let job = BlockOperation(); exportWork = job
        job.addExecutionBlock { [weak self, weak job] in
            guard let job, !job.isCancelled else { return }
            do { try AgentAuditExport.write(archive: selected, root: AgentPrivateStore.root, password: secret, destination: destination, cancelled: { job.isCancelled }); DispatchQueue.main.async { self?.status.stringValue = "加密导出完成。" } }
            catch { DispatchQueue.main.async { self?.status.stringValue = error.localizedDescription } }
        }
        workQueue.addOperation(job)
    }
}
