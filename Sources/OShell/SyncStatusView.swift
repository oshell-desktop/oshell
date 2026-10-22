// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class SyncStatusView: NSView {
    private weak var sync: WebDAVSync?
    private let immediate: Bool
    private var observer: NSObjectProtocol?
    var onUnlock: (() -> Void)? { didSet { refresh() } }
    var onLayoutChange: (() -> Void)?
    private var displayedMark: SyncStatusPresentation.Mark?
    private let icon = NSImageView()
    private let heading = NSTextField(labelWithString: "同步状态")
    private let progress = NSProgressIndicator()
    private let backend = NSTextField(labelWithString: "")
    private let times = NSTextField(wrappingLabelWithString: "")
    private let pending = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let run = NSButton(title: "关闭设置后同步", target: nil, action: nil)
    private let stop = NSButton(title: "取消本次", target: nil, action: nil)
    init(sync: WebDAVSync?, immediate: Bool = false) {
        self.sync = sync; self.immediate = immediate
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 258))
        identifier = .init("sync.status.card")
        heading.font = .systemFont(ofSize: 16, weight: .semibold); heading.identifier = .init("sync.status.title")
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true; icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let header = NSStackView(views: [icon, heading, NSView()]); header.spacing = 8
        times.identifier = .init("sync.status.times"); pending.identifier = .init("sync.status.pending"); detail.identifier = .init("sync.status.detail")
        for label in [backend, times, pending, detail, hint] { label.font = .systemFont(ofSize: 12) }
        detail.maximumNumberOfLines = 3; detail.lineBreakMode = .byWordWrapping
        times.maximumNumberOfLines = 3; hint.maximumNumberOfLines = 5
        hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 11)
        run.target = self; run.action = #selector(syncNow); run.identifier = .init("sync.status.run")
        run.toolTip = "关闭设置后使用已保存的配置进行同步；不会应用尚未保存的设置。"
        stop.target = self; stop.action = #selector(cancelSync); stop.identifier = .init("sync.status.cancel")
        let logs = NSButton(title: "查看日志…", target: self, action: #selector(showLogs)); logs.identifier = .init("sync.status.logs")
        let export = NSButton(title: "导出诊断日志…", target: self, action: #selector(exportLogs)); export.identifier = .init("sync.status.export")
        for button in [run, stop, logs, export] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [run, stop, logs, export]); buttons.spacing = 8
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        progress.identifier = .init("sync.status.progress")
        progress.isDisplayedWhenStopped = true
        let stack = NSStackView(views: [header, backend, times, pending, detail, progress, buttons, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            times.widthAnchor.constraint(equalTo: stack.widthAnchor), detail.widthAnchor.constraint(equalTo: stack.widthAnchor), hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        observer = NotificationCenter.default.addObserver(forName: WebDAVSync.statusDidChange, object: sync, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func date(_ value: Date?) -> String { value.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "暂无" }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill(); shape.fill()
        NSColor.gridColor.withAlphaComponent(0.6).setStroke(); shape.lineWidth = 0.6; shape.stroke()
    }
    @available(macOS 10.14, *)
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); displayedMark = nil; refresh() }
    func refresh() {
        let presentation = SyncStatusPresentation(sync: sync)
        heading.stringValue = presentation.title; heading.textColor = presentation.color
        if displayedMark != presentation.mark { icon.image = presentation.image; displayedMark = presentation.mark }
        guard let sync else {
            progress.isHidden = true
            detail.stringValue = "请选择下方同步方式。"; run.isEnabled = false; stop.isEnabled = false; return
        }
        let working = sync.busy && presentation.mark == .working
        progress.isHidden = !presentation.enabled || (!sync.busy && ![.success, .failed, .conflict, .cancelled].contains(sync.phase))
        progress.isIndeterminate = working
        progress.doubleValue = presentation.mark == .complete ? 1 : 0
        progress.setAccessibilityLabel(presentation.title)
        progress.toolTip = "显示当前同步阶段；不代表文件传输百分比或 iCloud 云端进度。"
        if working { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let duration = sync.summary.durationMS.map { String(format: " · 最近耗时 %.1f 秒", Double($0) / 1000) } ?? ""
        backend.stringValue = "当前已保存配置：" + (presentation.enabled ? presentation.backendName : "未启用") + duration
        times.stringValue = "最近成功：\(date(sync.summary.lastSuccess))    最近尝试：\(date(sync.summary.lastAttempt))\n下次自动检查 / 重试：\(sync.nextCheck.map { date($0) } ?? "未安排")"
        pending.stringValue = "本地改动：" + (!presentation.enabled ? "仅保存在本机" : sync.pendingLocalChanges.map { $0 ? "已保存，等待同步" : "暂无待同步修改" } ?? "待首次比较确认")
        let error = presentation.enabled && !sync.busy ? sync.recentError : nil
        detail.stringValue = presentation.guidance + (error.map { "\n上次错误：" + $0 } ?? "")
        detail.toolTip = detail.stringValue; detail.textColor = error == nil ? .secondaryLabelColor : .systemOrange
        let schedule = !presentation.enabled ? "选择同步方式并应用后启用；设置草稿不会立即更改当前同步。" : sync.manualQueued ? "关闭设置后开始；若修改了连接配置，请先点击“应用”。" : "设置打开时暂停新的检查；关闭后按已保存策略执行。"
        let cloud = presentation.directory && sync.phase != .success ? "iCloud 云端进度请在 Finder 查看。" : ""
        hint.stringValue = sync.diagnostics.writeIssue ?? sync.policyError ?? (sync.policy.summary + "\n" + (immediate ? "点击“立即同步”使用已保存的配置执行；关闭此窗口不会取消同步。" : schedule) + cloud)
        run.title = (presentation.mark == .locked) ? "解锁主密码…" : (sync.manualQueued ? "已安排同步" : (immediate ? "立即同步" : "关闭设置后同步"))
        run.toolTip = (presentation.mark == .locked) ? "解锁主密码以继续同步。" : (immediate ? "立即使用已保存的配置同步，支持自动和手动模式。" : "关闭设置后使用已保存配置同步；未应用的修改不会保存。")
        run.isEnabled = presentation.enabled && !sync.busy && !sync.manualQueued && (!(presentation.mark == .locked) || onUnlock != nil)
        stop.isEnabled = sync.busy || sync.manualQueued
        needsLayout = true; needsDisplay = true; onLayoutChange?()
    }
    @objc private func syncNow() {
        if sync?.isLocked == true { onUnlock?() } else if immediate { sync?.sync(interactive: true) } else { sync?.queueManualSync() }
        refresh()
    }
    @objc private func cancelSync() { sync?.cancelCurrent(); refresh() }
    @objc private func exportLogs() {
        guard let sync else { return }
        let panel = NSSavePanel(); panel.title = "导出同步诊断日志"; panel.nameFieldStringValue = "OShell-sync-diagnostics.json"; panel.allowedFileTypes = ["json"]
        guard panel.runPopupModal() == .OK, let url = panel.url else { return }
        do { try PrivateFile.write(sync.diagnostics.export(), to: url) }
        catch { Dialogs.message("无法导出诊断日志：" + error.localizedDescription) }
    }
    @objc private func showLogs() {
        guard let sync else { return }
        let alert = PopupAlert(); alert.messageText = "本地同步诊断日志"
        alert.informativeText = "记录时间、阶段、结果和错误代码；不记录密码、账号、地址、目录路径或会话内容。最多保留 7 天 / 2000 条 / 1 MiB，不参与同步。"
        alert.addButton(withTitle: "关闭"); alert.addButton(withTitle: "导出…"); alert.addButton(withTitle: "清空日志")
        let (scroll, editor) = textEditor("", editable: false); scroll.frame = NSRect(x: 0, y: 0, width: 740, height: 360); alert.accessoryView = scroll
        editor.identifier = .init("sync.logs.content")
        while true {
            let events = sync.diagnostics.entries()
            editor.string = events.isEmpty ? "暂无同步日志。" : events.reversed().map { entry in
                let backend = entry.backend == .directory ? "目录" : (entry.backend == .webDAV ? "WebDAV" : "本地")
                let run = entry.run.map { " · " + String($0.uuidString.prefix(8)) } ?? ""
                let duration = entry.durationMS.map { " · \($0) ms" } ?? ""
                return "\(date(entry.date)) [\(backend)] \(entry.event.title)\(entry.manual ? " · 手动" : "")\(run)\(duration)" + (entry.failure.map { "\n  " + $0.text } ?? "")
            }.joined(separator: "\n")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { exportLogs() }
            else if response == .alertThirdButtonReturn { sync.diagnostics.clear(); refresh() }
            else { break }
        }
    }
}
