// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

private final class AICommandCard: NSView {
    init(content: NSView) {
        super.init(frame: .zero); content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), content.topAnchor.constraint(equalTo: topAnchor, constant: 8), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill(); path.fill(); NSColor.gridColor.setStroke(); path.stroke()
    }
}
private final class AIActionButton: NSButton {
    var perform: (() -> Void)?
    convenience init(_ title: String, _ perform: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil); self.perform = perform
        target = self; action = #selector(run); bezelStyle = .rounded; controlSize = .small
    }
    @objc private func run() { perform?() }
}
final class AIPromptEditor: NSTextView {
    var onSend: (() -> Void)?, onImage: ((TerminalClipboardImage) -> Void)?
    override func paste(_ sender: Any?) {
        do { if let image = try TerminalClipboardImage.read(.general) { onImage?(image); return } }
        catch { Dialogs.message(error.localizedDescription); return }
        super.paste(sender)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command { onSend?(); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        do { if let image = try TerminalClipboardImage.read(sender.draggingPasteboard) { onImage?(image); return true } }
        catch { Dialogs.message(error.localizedDescription) }
        return false
    }
}

final class AIAssistantView: InterfaceSurfaceView, NSTextViewDelegate {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private weak var workspace: WorkspaceController?, pane: TerminalPane?
    private(set) var session: AIAssistantSession?
    private let target = NSTextField(wrappingLabelWithString: "选择一个终端会话，或先配置 AI 服务。")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let mode = NSSegmentedControl(labels: ["排查故障", "编写命令", "解释命令"], trackingMode: .selectOne, target: nil, action: nil)
    private let editor = AIPromptEditor(), send = NSButton(title: "审阅并发送 ⌘↩", target: nil, action: nil), stop = NSButton(title: "停止", target: nil, action: nil)
    private let transcript = NSScrollView(), document = Document(), messages = NSStackView()
    private let attachmentsScroll = NSScrollView(), attachmentsDocument = Document(), attachmentsStack = NSStackView()
    private var attachmentsHeight: NSLayoutConstraint!
    private var observers = [NSObjectProtocol](), rendering = false
    private var detached: AIAssistantWindow?
    var isDetachedVisible: Bool { detached?.window?.isVisible == true }
    init(workspace: WorkspaceController) {
        self.workspace = workspace; super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        identifier = .init("ai.assistant"); wantsLayer = true
        func button(_ title: String, _ action: @escaping () -> Void) -> NSButton { AIActionButton(title, action) }
        let heading = NSTextField(labelWithString: "AI 助手"); heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let settings = button("配置") { [weak self] in self?.workspace?.showAISettings() }; settings.identifier = .init("ai.configure")
        let detach = button("独立窗口") { [weak self] in self?.detach() }
        let close = button("收起") { [weak self] in self?.hide() }
        let header = NSStackView(views: [heading, NSView(), settings, detach, close]); header.spacing = 4
        target.font = .systemFont(ofSize: 12); target.maximumNumberOfLines = 3; target.identifier = .init("ai.target")
        mode.target = self; mode.action = #selector(modeChanged); mode.selectedSegment = 0; mode.identifier = .init("ai.mode")
        let new = button("新对话") { [weak self] in self?.newConversation() }
        let history = button("历史") { [weak self] in self?.showHistory() }
        let record = button("处理记录") { [weak self] in self?.showRecord() }
        let forget = button("清空发送历史") { [weak self] in self?.session?.clearSendHistory() }; forget.toolTip = "保留本机对话显示；清空后不能再从历史选择资料发送。"
        let back = button("当前会话") { [weak self] in self?.bind(self?.workspace?.selectedPaneForAI, force: true) }
        let tools = NSStackView(views: [new, history, record, back, forget]); tools.spacing = 4
        let add = NSPopUpButton(frame: .zero, pullsDown: true); add.identifier = .init("ai.addContext")
        add.addItem(withTitle: "＋添加上下文")
        for (index, name) in ["选中的文字", "当前屏幕快照", "最近 100 行", "最近 300 行", "最近 1000 行", "图片…", "文本文件…"].enumerated() {
            let item = NSMenuItem(title: name, action: #selector(addContext(_:)), keyEquivalent: ""); item.tag = index; item.target = self; add.menu?.addItem(item)
        }
        let preview = button("选择发送范围") { [weak self] in self?.previewRequest() }; preview.identifier = .init("ai.preview")
        let context = NSStackView(views: [add, preview]); context.spacing = 6
        for (scroll, doc, stack) in [(transcript, document, messages), (attachmentsScroll, attachmentsDocument, attachmentsStack)] {
            scroll.documentView = doc; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4), stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4)])
        }
        attachmentsHeight = attachmentsScroll.heightAnchor.constraint(equalToConstant: 0)
        let input = NSScrollView(); input.hasVerticalScroller = true; input.borderType = .bezelBorder; input.documentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 380, height: 86); editor.minSize = NSSize(width: 0, height: 86); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = false; editor.font = .systemFont(ofSize: 13); editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self; editor.identifier = .init("ai.prompt")
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.onSend = { [weak self] in self?.sendPrompt() }; editor.onImage = { [weak self] image in self?.attach(image: image, name: "剪贴板图片") }
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        send.target = self; send.action = #selector(sendPrompt); send.bezelStyle = .rounded; send.identifier = .init("ai.send")
        stop.target = self; stop.action = #selector(stopGenerating); stop.bezelStyle = .rounded; stop.identifier = .init("ai.stop")
        let hint = NSTextField(labelWithString: "↩ 换行 · 命令不会自动执行"); hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [hint, NSView(), stop, send]); actions.spacing = 6
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3; status.identifier = .init("ai.status")
        let stack = NSStackView(views: [header, target, tools, mode, transcript, context, attachmentsScroll, input, actions, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 60), input.heightAnchor.constraint(equalToConstant: 86), attachmentsHeight,
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)] + [header, target, tools, mode, transcript, context, attachmentsScroll, input, actions, status].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        observers.append(NotificationCenter.default.addObserver(forName: AIAssistantSession.didChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let changed = note.object as? AIAssistantSession, self.session === changed else { return }; self.render()
        })
        observers.append(NotificationCenter.default.addObserver(forName: AISettings.didChange, object: nil, queue: .main) { [weak self] _ in self?.workspace?.refreshAIShortcut(); self?.render() })
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func show() {
        guard let workspace else { return }
        if (workspace.aiHost?.bounds.width ?? 0) < 1040 || (workspace.aiHost?.bounds.height ?? 0) < 600 { detach() }
        else {
            detached?.close(); detached = nil; removeFromSuperview()
            if let host = workspace.aiHost { frame = host.assistant.bounds; autoresizingMask = [.width, .height]; host.assistant.addSubview(self); host.showing = true; host.layoutSubtreeIfNeeded() }
        }
        workspace.aiButton.state = .on; bind(workspace.selectedPaneForAI, force: true); render()
    }
    func hide() { detached?.close(); workspace?.aiHost?.showing = false; workspace?.aiButton.state = .off; workspace?.selectedPaneForAI?.activate() }
    func detach() {
        guard let workspace else { return }
        if let detached { detached.window?.makeKeyAndOrderFront(nil); return }
        removeFromSuperview(); workspace.aiHost?.showing = false
        let controller = AIAssistantWindow(view: self); detached = controller
        controller.onClose = { [weak self] in self?.workspace?.aiButton.state = .off }
        controller.window?.center(); controller.window?.makeKeyAndOrderFront(nil); workspace.aiButton.state = .on
        bind(workspace.selectedPaneForAI)
    }
    func shutdown() { detached?.close(); detached = nil; removeFromSuperview() }
    func bind(_ pane: TerminalPane?, force: Bool = false) {
        if !force, self.pane === pane, session?.archived == true { return }
        self.pane = pane
        guard let pane else { session = nil; render(); return }
        let target = pane.aiTarget
        if pane.aiSession?.target.stamp != target.stamp {
            if let prior = pane.aiSession { prior.cancel(); AIHistory.shared.remember(prior) }
            pane.aiSession = AIAssistantSession(target: target)
        }
        pane.aiSession?.refreshTarget(target)
        guard session !== pane.aiSession else { self.target.stringValue = target.title; self.target.toolTip = target.metadata; return }
        session = pane.aiSession; render()
    }
    func useMode(_ value: Int) {
        guard let session, !session.busy, !session.archived else { return }
        session.mode = value
        if session.draft.isEmpty { session.draft = ["请分析异常表现和附加输出，区分事实与假设，并给出下一步检查命令。", "我想完成：", "请解释这条命令的作用、参数、影响范围与注意事项："][min(max(0, value), 2)] }
        render(); window?.makeFirstResponder(editor)
    }
    @objc private func modeChanged() { useMode(mode.selectedSegment) }
    func textDidChange(_ notification: Notification) { if !rendering { session?.draft = editor.string } }
    func attach(text: String, name: String) {
        guard let session, !session.busy, !session.archived else { return }
        guard !text.isEmpty, text.count <= 64000, session.attachments.count < 4 else { status.stringValue = "文字为空、超过 64000 字符或附件已达 4 份，请缩小选择范围。"; return }
        session.attachments.append(.init(name: name, text: AIPrivacy.clean(text))); render()
    }
    func attach(image: TerminalClipboardImage, name: String) {
        guard let session, !session.busy, !session.archived else { return }
        guard image.png.count <= 4 * 1024 * 1024, session.images.count < 4 else { status.stringValue = "单张图片最多 4 MiB，最多添加 4 张图片。"; return }
        session.images.append(.init(name: name, png: image.png)); render()
    }
    @objc private func addContext(_ sender: NSMenuItem) {
        guard let session, !session.busy, !session.archived else { return }
        if sender.tag <= 4 {
            guard let pane else { return }
            if sender.tag == 0 { attach(text: pane.terminal.selection.getSelectedText(), name: "所选文字") }
            else { let lines = sender.tag == 1 ? nil : [100, 300, 1000][sender.tag - 2]; attach(text: pane.aiOutput(lines: lines), name: lines.map { "最近 \($0) 行快照" } ?? "当前屏幕快照") }
        } else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.allowedFileTypes = sender.tag == 5 ? ["png", "jpg", "jpeg", "tiff", "webp", "heic"] : ["txt", "log", "conf", "json", "yaml", "yml", "md", "sh"]
            guard panel.runPopupModal() == .OK, let url = panel.url else { return }
            do {
                let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard info.isRegularFile == true, let size = info.fileSize, size <= (sender.tag == 5 ? 20 * 1024 * 1024 : 128 * 1024) else { throw ModelError.invalid("附件文件过大或不是普通文件。") }
                let data = try Data(contentsOf: url)
                if sender.tag == 5 { attach(image: try TerminalClipboardImage.decode(data), name: url.lastPathComponent) }
                else { guard let text = String(data: data, encoding: .utf8) else { throw ModelError.invalid("文本附件需使用 UTF-8 编码。") }; attach(text: text, name: url.lastPathComponent) }
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func sendPrompt() {
        guard let session, !session.busy, !session.archived else { return }
        session.draft = editor.string
        do {
            let settings = try AISettings.load()
            guard pane?.aiTarget.stamp == session.target.stamp else { throw ModelError.invalid("目标会话已变化，请返回当前会话并重新分析。") }
            guard let snapshot = AISendReview.review(draft: try session.sendDraft(), settings: settings, revoke: { [weak session] id in
                session?.revoke(id); return try? session?.sendDraft()
            }) else { return }
            let authorization = try session.authorize(snapshot, settings: { try AISettings.load() }, target: { [weak self] in self?.pane?.aiTarget })
            try session.send(authorization)
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func stopGenerating() { session?.cancel() }
    private func previewRequest() { sendPrompt() }
    private func showText(_ title: String, _ text: String) {
        let alert = PopupAlert(); alert.messageText = title; alert.addButton(withTitle: "关闭")
        let (scroll, editor) = textEditor(text, editable: false); scroll.frame = NSRect(x: 0, y: 0, width: 680, height: 400); alert.accessoryView = scroll; editor.isSelectable = true; alert.runModal()
    }
    private func newConversation() {
        guard let pane, pane.aiSession?.busy != true else { status.stringValue = "请先停止当前生成。"; return }
        if let prior = pane.aiSession { AIHistory.shared.remember(prior) }
        pane.aiSession = AIAssistantSession(target: pane.aiTarget); bind(pane, force: true)
    }
    private func showHistory() {
        let entries = AIHistory.shared.entries
        guard !entries.isEmpty else { status.stringValue = AIHistory.shared.error ?? "暂无历史记录；完成的对话会出现在这里。"; return }
        let alert = PopupAlert(); alert.messageText = "本机 AI 历史"; alert.informativeText = "历史只读，命令不会直接填入其他会话。"
        alert.addButton(withTitle: "打开"); alert.addButton(withTitle: "取消")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 600, height: 28), pullsDown: false)
        for (index, entry) in entries.enumerated() { let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: ""); item.tag = index; picker.menu?.addItem(item) }
        alert.accessoryView = picker
        if alert.runModal() == .alertFirstButtonReturn, let index = picker.selectedItem?.tag, entries.indices.contains(index) { session = AIAssistantSession(archive: entries[index]); render() }
    }
    private func showRecord() {
        guard let session, !session.messages.isEmpty else { return }
        let alert = PopupAlert(); alert.messageText = "处理记录"; alert.informativeText = "记录实际问题和 AI 建议；不表示建议命令已执行或故障已解决。"
        alert.addButton(withTitle: "复制记录"); alert.addButton(withTitle: "保存到本机…"); alert.addButton(withTitle: "取消")
        let (scroll, editor) = textEditor(session.record, editable: false); scroll.frame = NSRect(x: 0, y: 0, width: 680, height: 380); editor.isSelectable = true; alert.accessoryView = scroll
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { copy(session.record) }
        else if response == .alertSecondButtonReturn {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "OShell-AI-处理记录.md"; panel.allowedFileTypes = ["md"]
            if panel.runPopupModal() == .OK, let url = panel.url { do { try PrivateFile.write(Data(session.record.utf8), to: url) } catch { status.stringValue = error.localizedDescription } }
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); status.stringValue = "已复制" }
    private func label(_ text: String, font: NSFont = .systemFont(ofSize: 12)) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = font; label.isSelectable = true; return label
    }
    private func clear(_ stack: NSStackView) { stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() } }
    private func add(_ view: NSView, to stack: NSStackView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    func render() {
        guard !rendering else { return }
        rendering = true; defer { rendering = false }; clear(messages); clear(attachmentsStack)
        if window?.isVisible == true && !isHiddenOrHasHiddenAncestor { session?.markRead() }
        let settings = try? AISettings.load()
        target.stringValue = session.map { "本机目标（未自动发送）：" + $0.target.title + ($0.archived ? " · 历史只读" : "") } ?? "选择一个终端会话后开始分析"
        target.toolTip = session?.target.metadata
        status.toolTip = session?.lastReceipt
        mode.selectedSegment = session?.mode ?? 0; editor.string = session?.draft ?? ""
        editor.isEditable = session != nil && session?.busy != true && session?.archived != true
        send.isEnabled = editor.isEditable; stop.isEnabled = session?.busy == true; mode.isEnabled = editor.isEditable
        status.stringValue = session?.status.isEmpty == false ? session!.status : "发送前逐项授权；默认不带会话信息、历史和旧图片。"
        if settings?.endpoint.isEmpty != false {
            add(label("先配置 AI 服务\n填写接口地址、模型和密钥，然后测试连接。"), to: messages)
            add(AIActionButton("配置 AI 服务") { [weak self] in self?.workspace?.showAISettings() }, to: messages)
        } else if session?.messages.isEmpty != false { add(label("选中报错后右键“用 AI 分析”；或选择上方入口，描述目标、范围和限制。"), to: messages) }
        if let session {
            if session.messages.count > 12 { add(label("此处显示最近 12 条消息；处理记录可查看完整内容。"), to: messages) }
            for message in session.messages.suffix(12) {
                add(label(message.role == "assistant" ? "AI · 建议尚未执行" : "你", font: .systemFont(ofSize: 12, weight: .semibold)), to: messages)
                let displayed = message.role == "assistant" ? AICommand.prose(message.text) : (message.displayText ?? message.text)
                let text = String(displayed.prefix(12000)) + (displayed.count > 12000 ? "\n…完整内容见处理记录" : "")
                add(label(text), to: messages)
                if !message.images.isEmpty { add(label("图片附件：" + message.images.map(\.name).joined(separator: "、")), to: messages) }
                if message.role == "assistant" {
                    for command in AICommand.parse(message.text) {
                        let code = label(command.text, font: .oshellMonospacedSystemFont(ofSize: 12, weight: .regular))
                        let note = label(command.impact, font: .systemFont(ofSize: 10)); note.textColor = .secondaryLabelColor
                        let copy = AIActionButton("复制") { [weak self] in self?.copy(command.text) }
                        let fill = AIActionButton("填入原会话") { [weak self, weak session] in
                            guard let self, let session, !session.archived else { return }
                            do { try self.workspace?.fillAICommand(command, target: session.target); self.status.stringValue = "已填入原会话，尚未回车执行。" } catch { self.status.stringValue = error.localizedDescription }
                        }
                        fill.identifier = .init("ai.command.fill"); fill.isEnabled = !session.archived && command.canFill
                        fill.toolTip = "仅在原会话的空闲命令行填入，不回车、不广播；无法确认时请复制。"
                        let save = AIActionButton("存为快速命令") { [weak self] in self?.workspace?.saveAICommand(command) }
                        let buttons = NSStackView(views: [copy, fill, save]); buttons.spacing = 4
                        let block = NSStackView(views: [code, note, buttons]); block.orientation = .vertical; block.alignment = .leading; block.spacing = 6
                        for view in [code, note] { view.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true }; add(AICommandCard(content: block), to: messages)
                    }
                }
            }
            for attachment in session.attachments {
                let preview = AIActionButton(attachment.name) { [weak self] in self?.showText(attachment.name, attachment.text) }
                let remove = AIActionButton("移除") { [weak self, weak session] in session?.attachments.removeAll { $0.id == attachment.id }; self?.render() }
                remove.isEnabled = !session.busy
                add(NSStackView(views: [preview, NSView(), remove]), to: attachmentsStack)
            }
            for (index, image) in session.images.enumerated() {
                let preview = AIActionButton("图片：" + image.name) { [weak self] in
                    guard let self else { return }; let alert = PopupAlert(); alert.messageText = image.name; alert.addButton(withTitle: "关闭")
                    let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 480, height: 320)); view.image = NSImage(data: image.png); view.imageScaling = .scaleProportionallyUpOrDown; alert.accessoryView = view; alert.runModal(); self.needsLayout = true
                }
                let remove = AIActionButton("移除") { [weak self, weak session] in if session?.images.indices.contains(index) == true { session?.images.remove(at: index) }; self?.render() }
                remove.isEnabled = !session.busy; add(NSStackView(views: [preview, NSView(), remove]), to: attachmentsStack)
            }
        }
        attachmentsHeight.constant = min(100, CGFloat(attachmentsStack.arrangedSubviews.count) * 30)
        needsLayout = true; layoutSubtreeIfNeeded()
        transcript.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - transcript.contentSize.height))); transcript.reflectScrolledClipView(transcript.contentView)
    }
    override func layout() {
        super.layout()
        for (scroll, doc, stack) in [(transcript, document, messages), (attachmentsScroll, attachmentsDocument, attachmentsStack)] {
            doc.setFrameSize(NSSize(width: scroll.contentSize.width, height: doc.frame.height)); doc.layoutSubtreeIfNeeded()
            let height = max(scroll.contentSize.height, stack.fittingSize.height + 8)
            if abs(doc.frame.height - height) > 0.5 { doc.setFrameSize(NSSize(width: scroll.contentSize.width, height: height)) }
        }
    }
}
