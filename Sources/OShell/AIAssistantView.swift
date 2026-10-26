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
/// Reflow when this viewport actually changes, not before its parent stack has
/// assigned the new frame. Nested message cards must follow sidebar resizing.
private final class AIConversationScroll: NSScrollView {
    weak var contentStack: NSStackView?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }
    override func layout() {
        super.layout()
        guard let doc = documentView, let stack = contentStack else { return }
        for _ in 0..<3 {
            tile(); let width = contentSize.width
            doc.setFrameSize(NSSize(width: width, height: doc.frame.height)); doc.layoutSubtreeIfNeeded()
            let height = max(contentSize.height, stack.fittingSize.height + 8)
            if abs(doc.frame.height - height) > 0.5 { doc.setFrameSize(NSSize(width: width, height: height)) }
            tile()
            if abs(contentSize.width - width) <= 0.5 { break }
        }
    }
}
final class AIPromptEditor: CommandTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() {
            ("随心输入" as NSString).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height), withAttributes: [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
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
    private var recordWindows = [AIRecordsWindow]()
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private weak var workspace: WorkspaceController?, pane: TerminalPane?
    private(set) var session: AIAssistantSession?
    private var standalone = AIAssistantSession(target: AITarget(paneID: UUID(), stamp: "standalone", title: "独立对话（未绑定终端）", metadata: ""))
    private var showingIndependent = false
    private var diagnostic: AIDiagnosticRun?
    #if OSHELL_TEST_HARNESS
    var taskForTesting: AIDiagnosticRun? { diagnostic }
    #endif
    private var receiptView: AISendReceiptView?
    private weak var receiptButton: NSButton?
    private var currentTarget: AITarget? { session === standalone ? standalone.target : diagnostic?.targetFor(pane: pane, session: session) ?? pane?.aiTarget }
    private weak var moreButton: NSButton?
    private let modelPicker = NSPopUpButton(), effortPicker = NSPopUpButton()
    private var modelChoices = [AIModelChoice]()
    private let target = NSTextField(wrappingLabelWithString: "选择一个终端会话，或先配置 AI 服务。")
    private let historyBinding = NSButton(title: "绑定这段对话到当前 SSH…", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let contextStatus = NSTextField(wrappingLabelWithString: "")
    private let editor = AIPromptEditor(frame: .zero, textContainer: nil), send = AIComposerSendButton(title: "发送", target: nil, action: nil), stop = AIComposerSendButton(title: "停止", target: nil, action: nil)
    private let transcript = AIConversationScroll(), document = Document(), messages = NSStackView()
    private let attachmentsScroll = AIConversationScroll(), attachmentsDocument = Document(), attachmentsStack = NSStackView()
    private var composer: AIComposerSurface!
    private let approval = NSButton(title: "请求批准", target: nil, action: nil)
    private var stopKeyMonitor: Any?
    private var stopGesture = AIStopGesture()
    private var observers = [NSObjectProtocol](), rendering = false
    private var canSendDraft = false
    private var detached: AIAssistantWindow?
    var isDetachedVisible: Bool { detached?.window?.isVisible == true }
    init(workspace: WorkspaceController) {
        self.workspace = workspace; super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        identifier = .init("ai.assistant"); wantsLayer = true
        func button(_ title: String, _ action: @escaping () -> Void) -> NSButton { AIActionButton(title, action) }
        let heading = NSTextField(labelWithString: "AI 助手"); heading.font = .systemFont(ofSize: 15, weight: .semibold)
        func icon(_ symbol: String, _ title: String, _ id: String, _ action: @escaping () -> Void) -> NSButton {
            let control = button(title, action); control.identifier = .init(id)
            control.bezelStyle = .recessed; (control.cell as? NSButtonCell)?.showsBorderOnlyWhileMouseInside = true
            control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            control.image?.size = NSSize(width: 15, height: 15); control.imagePosition = .imageOnly
            control.imageScaling = .scaleProportionallyDown; control.contentTintColor = .secondaryLabelColor
            control.toolTip = title; control.setAccessibilityLabel(title)
            NSLayoutConstraint.activate([control.widthAnchor.constraint(equalToConstant: 28), control.heightAnchor.constraint(equalToConstant: 26)])
            return control
        }
        let new = icon("plus", "新对话", "ai.new") { [weak self] in self?.newConversation() }
        let history = icon("clock.arrow.circlepath", "对话历史", "ai.history") { [weak self] in self?.showHistory() }
        let settings = icon("gearshape", "AI 设置", "ai.configure") { [weak self] in self?.workspace?.showAISettings() }
        let preview = icon("doc.text.magnifyingglass", "发送记录", "ai.preview") { [weak self] in self?.previewRequest() }; receiptButton = preview
        let more = icon("ellipsis", "更多操作", "ai.more") { [weak self] in self?.showMore() }; moreButton = more
        let close = icon("xmark", "收起助手", "ai.hide") { [weak self] in self?.hide() }
        let header = NSStackView(views: [heading, NSView(), new, history, settings, preview, more, close]); header.spacing = 3
        historyBinding.target = self; historyBinding.action = #selector(bindHistoryToCurrentSSH)
        historyBinding.identifier = .init("ai.history.bindCurrent"); historyBinding.bezelStyle = .rounded; historyBinding.isHidden = true
        target.font = .systemFont(ofSize: 11); target.textColor = .secondaryLabelColor
        target.maximumNumberOfLines = 1; target.lineBreakMode = .byTruncatingMiddle; target.identifier = .init("ai.target")
        let add = AIComposerAddButton(frame: .zero, pullsDown: true); add.identifier = .init("ai.addContext")
        add.addItem(withTitle: "＋"); add.toolTip = "添加上下文：文字、终端快照、图片或文件"; add.setAccessibilityLabel("添加上下文")
        (add.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        add.isBordered = false; add.font = AIComposerTypography.controlFont; add.menu?.font = AIComposerTypography.controlFont
        for (index, name) in ["选中的文字", "当前屏幕快照", "最近 100 行", "最近 300 行", "最近 1000 行", "图片…", "文本文件…"].enumerated() {
            let item = NSMenuItem(title: name, action: #selector(addContext(_:)), keyEquivalent: ""); item.tag = index; item.target = self; add.menu?.addItem(item)
        }
        approval.identifier = .init("ai.approval"); approval.target = self; approval.action = #selector(showApprovalMenu)
        approval.isBordered = false; approval.font = AIComposerTypography.controlFont
        approval.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "SSH 审批")
        approval.image?.size = NSSize(width: 15, height: 15); approval.imagePosition = .imageLeading
        approval.contentTintColor = .secondaryLabelColor
        modelPicker.cell = AIComposerPickerCell(textCell: "", pullsDown: false)
        let effortCell = AIComposerPickerCell(textCell: "", pullsDown: false); effortCell.showsEffort = true; effortPicker.cell = effortCell
        (modelPicker.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        modelPicker.cell?.alignment = .right
        modelPicker.isBordered = false; effortPicker.isBordered = false
        modelPicker.font = AIComposerTypography.controlFont; effortPicker.font = AIComposerTypography.controlFont
        modelPicker.target = self; modelPicker.action = #selector(modelChanged); modelPicker.identifier = .init("ai.model")
        modelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); modelPicker.cell?.lineBreakMode = .byTruncatingMiddle
        effortPicker.target = self; effortPicker.action = #selector(effortChanged); effortPicker.identifier = .init("ai.reasoningEffort")
        effortPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        effortPicker.cell?.lineBreakMode = .byTruncatingTail
        modelPicker.controlSize = .small; effortPicker.controlSize = .small
        modelPicker.font = AIComposerTypography.controlFont; effortPicker.font = AIComposerTypography.controlFont
        modelPicker.setAccessibilityLabel("模型"); effortPicker.setAccessibilityLabel("推理设置")
        for (scroll, doc, stack) in [(transcript, document, messages), (attachmentsScroll, attachmentsDocument, attachmentsStack)] {
            scroll.documentView = doc; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
            scroll.contentStack = stack
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4), stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4)])
        }
        messages.spacing = 18
        let input = NSScrollView(); input.hasVerticalScroller = true; input.autohidesScrollers = true; input.drawsBackground = false; input.borderType = .noBorder; input.documentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 380, height: 86); editor.minSize = NSSize(width: 0, height: 86); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = false; editor.font = .systemFont(ofSize: 14); editor.drawsBackground = false; editor.textColor = .labelColor; editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self; editor.identifier = .init("ai.prompt")
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.onSend = { [weak self] in self?.sendPrompt() }; editor.onImage = { [weak self] image in self?.attach(image: image, name: "剪贴板图片") }
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        send.target = self; send.action = #selector(sendPrompt); send.isBordered = false; send.identifier = .init("ai.send")
        send.setAccessibilityLabel("发送消息"); send.toolTip = "发送消息（⌘Return）；Return 换行"
        stop.target = self; stop.action = #selector(stopGenerating); stop.isBordered = false; stop.identifier = .init("ai.stop"); stop.showsStop = true
        stop.setAccessibilityLabel("停止生成与任务"); stop.toolTip = "停止生成及后续任务操作"
        let hint = NSTextField(labelWithString: "⌘↩ 发送 · ↩ 换行"); hint.identifier = .init("ai.routing")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        hint.toolTip = "直接提问，自动处理聊天、命令辅助和持续排查。SSH 操作仍按审批策略执行。"
        composer = AIComposerSurface(input: input, attachments: attachmentsScroll, add: add, approval: approval, model: modelPicker, effort: effortPicker, send: send, stop: stop)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3; status.identifier = .init("ai.status")
        contextStatus.identifier = .init("ai.context.usage"); contextStatus.font = .systemFont(ofSize: 10); contextStatus.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, target, historyBinding, transcript, composer!, hint, contextStatus, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)] + [header, target, historyBinding, transcript, composer!, hint, contextStatus, status].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        observers.append(NotificationCenter.default.addObserver(forName: AIAssistantSession.didChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let changed = note.object as? AIAssistantSession else { return }
            if self.session === changed { self.render() }

        })
        observers.append(NotificationCenter.default.addObserver(forName: AISettings.didChange, object: nil, queue: .main) { [weak self] _ in self?.workspace?.refreshAIShortcut(); self?.diagnostic?.observe(); self?.render() })
        stopKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.modalWindow == nil, event.window === self.window,
                  self.session?.busy == true || (self.diagnostic?.active == true && self.diagnostic?.belongs(to: self.session) == true),
                  let responder = event.window?.firstResponder as? NSView, responder.isDescendant(of: self) else { return event }
            let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
            let bytes: [UInt8] = event.keyCode == 8 && flags == .control ? [3] : event.keyCode == 53 && flags.isEmpty ? [27] : []
            if !event.isARepeat, self.stopGesture.consume(bytes) { self.stopGenerating() }
            return bytes.isEmpty ? event : nil
        }
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let stopKeyMonitor { NSEvent.removeMonitor(stopKeyMonitor) }; observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func show() {
        guard let workspace else { return }
        if (workspace.aiHost?.bounds.width ?? 0) < 1040 || (workspace.aiHost?.bounds.height ?? 0) < 600 { detach() }
        else {
            detached?.close(); detached = nil; removeFromSuperview()
            if let host = workspace.aiHost { frame = host.assistant.bounds; autoresizingMask = [.width, .height]; host.assistant.addSubview(self); host.showing = true; host.layoutSubtreeIfNeeded() }
        }
        workspace.aiButton.state = .on; bind(workspace.selectedPaneForAI, force: !showingIndependent); render()
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
    func shutdown() { diagnostic?.cancel(); standalone.cancel(); detached?.close(); detached = nil; removeFromSuperview() }
    func bind(_ pane: TerminalPane?, force: Bool = false) {
        if !force, showingIndependent { return }
        if force { showingIndependent = false }
        if !force, self.pane === pane, session?.archived == true { return }
        self.pane = pane
        guard let pane else { if session !== standalone { session = standalone; render() }; return }
        let target = diagnostic?.targetFor(pane: pane, session: pane.aiSession) ?? pane.aiTarget
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
        session.mode = 0
        if session.draft.isEmpty && value != 3 { session.draft = ["请分析异常表现和附加输出；需要现场证据时继续只读排查，给出有证据的结论。", "我想完成：", "请解释这条命令的作用、参数、影响范围与注意事项：", "请描述当前 SSH 会话的故障，例如：nginx 请求异常，请检查 error 日志并给出处理建议。"][min(max(0, value), 3)] }
        render(); window?.makeFirstResponder(editor)
    }
    @objc private func modelChanged() {
        guard let choice = modelPicker.selectedItem?.representedObject as? AIModelSelection,
              modelChoices.contains(where: { $0.selection == choice }), session?.busy != true else { return }
        session?.selectModel(choice)
    }
    @objc private func effortChanged() {
        guard effortPicker.isEnabled, let session else { return }
        let index = effortPicker.indexOfSelectedItem
        if index == 0 { session.selectReasoning(nil) }
        else if index == 1 { session.selectReasoning(.init(effort: nil)) }
        else if AIReasoningEffort.allCases.indices.contains(index - 2), effortPicker.selectedItem?.isEnabled == true {
            session.selectReasoning(.init(effort: AIReasoningEffort.allCases[index - 2]))
        }
    }
    private func refreshEffortPicker(_ settings: AISettings?) {
        let configured = try? settings?.resolved(for: session?.modelSelection)
        effortPicker.removeAllItems()
        effortPicker.addItems(withTitles: ["跟随模型：" + (configured?.reasoningEffort?.title ?? "服务端默认"), "服务端默认"] + AIReasoningEffort.allCases.map(\.title))
        effortPicker.menu?.font = AIComposerTypography.controlFont
        effortPicker.menu?.autoenablesItems = false
        for (index, item) in effortPicker.itemArray.enumerated() where index >= 2 {
            item.isEnabled = configured.map { AIReasoningEffort.allCases[index - 2].supports($0.protocolType) } ?? false
        }
        let index = session?.reasoningOverride.map { override in override.effort.flatMap { AIReasoningEffort.allCases.firstIndex(of: $0) }.map { $0 + 2 } ?? 1 } ?? 0
        effortPicker.selectItem(at: index)
        effortPicker.isEnabled = configured != nil && session != nil && session?.busy != true && session?.archived != true
        effortPicker.toolTip = (effortPicker.titleOfSelectedItem ?? "推理设置") + "\n默认跟随所选模型的思考强度；手动调整仅影响当前对话，切换模型后恢复该模型的设置。更改后需重新授权发送，支持档位以模型和渠道为准。"
    }
    private func refreshModelPicker(_ settings: AISettings?) {
        if let settings { session?.initializeModel(from: settings) }
        modelChoices = settings?.modelChoices ?? []; modelPicker.removeAllItems()
        let selected = modelChoices.firstIndex { $0.selection == session?.modelSelection }
        if selected == nil {
            let item = NSMenuItem(title: modelChoices.isEmpty ? "请先配置渠道和模型" : "所选模型不可用，请重新选择", action: nil, keyEquivalent: ""); item.tag = -1
            modelPicker.menu?.addItem(item)
        }
        for (index, choice) in modelChoices.enumerated() {
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: ""); item.tag = index; item.representedObject = choice.selection; modelPicker.menu?.addItem(item)
        }
        modelPicker.menu?.font = AIComposerTypography.controlFont
        if let selected { modelPicker.selectItem(at: selected) }
        modelPicker.isEnabled = session != nil && session?.archived != true && session?.busy != true && !modelChoices.isEmpty
        refreshEffortPicker(settings)
        modelPicker.toolTip = (modelChoices.first { $0.selection == session?.modelSelection }?.title ?? "请选择模型") + "\n" + ((try? settings?.resolved(for: session?.modelSelection).validatedURL().absoluteString) ?? "在设置中配置渠道和模型；切换不会发送内容。")
    }
    func textDidChange(_ notification: Notification) {
        if !rendering {
            session?.draft = editor.string; editor.needsDisplay = true
            send.isEnabled = canSendDraft && !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            send.needsDisplay = true
        }
    }
    func attach(text: String, name: String) {
        guard let session, !session.busy, !session.archived else { return }
        guard !text.isEmpty, text.count <= AISettings.maximumContextCharacters, session.attachments.count < 4 else { status.stringValue = "文字为空、超过 \(AISettings.maximumContextCharacters) 字符或附件已达 4 份，请缩小选择范围。"; return }
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
                guard info.isRegularFile == true, let size = info.fileSize, size <= (sender.tag == 5 ? 20 * 1024 * 1024 : 4 * 1024 * 1024) else { throw ModelError.invalid("附件文件过大或不是普通文件。") }
                let data = try Data(contentsOf: url)
                if sender.tag == 5 { attach(image: try TerminalClipboardImage.decode(data), name: url.lastPathComponent) }
                else { guard let text = String(data: data, encoding: .utf8) else { throw ModelError.invalid("文本附件需使用 UTF-8 编码。") }; attach(text: text, name: url.lastPathComponent) }
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func sendPrompt() { performSend(review: false) }
    @objc func reviewAndSend() { performSend(review: true) }
    private func performSend(review: Bool, automatic: Bool = false, contextPrepared: Bool = false) {
        guard let session, !session.busy, !session.archived else { return }
        do {
            if !automatic && !contextPrepared {
                let message = editor.string
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.invalid("请先输入问题。") }
                session.draft = message
                if let run = diagnostic, run.active, run.belongs(to: session) {
                    try run.prepareUserContinuation(message)
                } else {
                    if AIInvestigationPlan.isContinuationRequest(message), let previous = diagnostic,
                       previous.belongs(to: session), previous.completed, !previous.wasDirectAnswer {
                        throw ModelError.invalid("原操作任务已完成。请说明新的目标或要复查的内容；本对话和上下文仍然保留。")
                    }
                    // A stopped task is a new execution run in the same chat.
                    // Its checkpoint supplies context; old permits are never reused.
                    if AIInvestigationPlan.isContinuationRequest(message), let previous = diagnostic,
                       let pane, let original = previous.restartQuestion(for: pane, conversation: session) {
                        session.draft = original
                    }
                    diagnostic?.cancel("已开始新的任务。")
                    session.setTaskInstruction(nil)
                }
                session.mode = 0
            }
            guard !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.invalid("请先输入问题。") }
            if !automatic && session === pane?.aiSession && pane?.canRunAIDiagnostics == true && diagnostic?.active != true {
                startDiagnostics(automaticRouting: true)
                guard self.session === session, diagnostic?.active == true else { return }
            }
            let settings = try session.requestSettings(from: AISettings.load())
            guard currentTarget?.paneID == session.target.paneID, currentTarget?.stamp == session.target.stamp else { throw ModelError.invalid("目标会话已变化，未发送。") }
            let needsContextConfirmation = try session.contextNeedsConfirmation(settings: settings)
            if !automatic && !review && needsContextConfirmation {
                let revision = session.revision
                let alert = PopupAlert(); alert.messageText = "携带此对话的上下文？"
                alert.informativeText = "接收渠道已变化，或这是从本机恢复的历史。是否把此对话已有的消息和已发送资料作为上下文发送给 \(settings.channelName ?? settings.provider.title) · \(settings.model)？只选取模型长度范围内较新的资料，不包含其他对话。"
                alert.addButton(withTitle: "携带上下文").identifier = .init("ai.context.include")
                alert.addButton(withTitle: "仅发送新问题").identifier = .init("ai.context.skip")
                alert.addButton(withTitle: "取消")
                let choice = alert.runModal()
                guard choice != .alertThirdButtonReturn, choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }
                guard self.session === session, session.revision == revision,
                      (try session.requestSettings(from: AISettings.load())) == settings else { throw ModelError.invalid("对话或接收渠道已变化，未发送。") }
                try session.decideContext(include: choice == .alertFirstButtonReturn, settings: settings)
            }
            if !review && !contextPrepared {
                if try session.compactContextIfNeeded(settings: settings, target: { [weak self] in self?.currentTarget }, completion: { [weak self, weak session] result in
                    guard let self, let session, self.session === session else { return }
                    switch result {
                    case .success: self.performSend(review: review, automatic: automatic, contextPrepared: true)
                    case .failure(let error): self.status.stringValue = error.localizedDescription; self.diagnostic?.pause("上下文压缩失败，原始记录已保留。")
                    }
                }) { return }
            }
            let draft: AISendDraft
            draft = try session.conversationDraft(settings: settings)
            let snapshot: AIRequest
            if review {
                guard let reviewed = AISendReview.review(draft: draft, settings: settings, revoke: { [weak session] id in
                    session?.revoke(id); return try? session?.conversationDraft(settings: settings)
                }) else { return }
                snapshot = reviewed
            } else {
                if automatic {
                    guard session.isDiagnosticPrepared, diagnostic?.paused == false, diagnostic?.belongs(to: session) == true else { throw ModelError.invalid("排查草稿已变化，未自动发送。") }
                    // Never silently include a newly attached image, identity field,
                    // prior chat or user draft in a task's automatic continuation.
                    let selected = session.diagnosticAttachmentIDs.union([draft.requiredID]).union(draft.contextIDs)
                    snapshot = try draft.freeze(settings: settings, selected: selected)
                } else { snapshot = try draft.freeze(settings: settings, selected: draft.defaults) }
            }
            // The Send action (or the active task's result callback) grants this
            // one frozen request; transport still rechecks target and settings.
            let authorization = try session.authorize(snapshot, settings: { [weak session] in
                guard let session else { throw ModelError.invalid("对话已关闭，未发送。") }
                return try session.requestSettings(from: AISettings.load())
            }, target: { [weak self] in self?.currentTarget })
            try session.send(authorization)
        } catch { status.stringValue = error.localizedDescription; if automatic { diagnostic?.pause("自动回传失败，任务暂停；请查看发送记录再决定是否继续。") } }
    }
    @objc private func stopGenerating() { if diagnostic?.belongs(to: session) == true { diagnostic?.stopByUser() }; session?.cancel() }
    private func previewRequest() {
        if let receiptView { receiptView.removeFromSuperview(); self.receiptView = nil; receiptButton?.title = "审阅" }
        else {
            let view = AISendReceiptView(receipts: session?.sendReceipts ?? [])
            view.wantsLayer = true; view.layer?.zPosition = 3; addSubview(view)
            receiptView = view; receiptButton?.title = "返回聊天"
        }
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    override func layout() {
        super.layout()
        receiptView?.frame = transcript.convert(transcript.bounds, to: self)
        receiptView?.layoutSubtreeIfNeeded()
    }
    private func showRecords(_ title: String, entries: [String]) {
        let viewer = AIRecordsWindow(title: title, entries: entries)
        recordWindows.append(viewer)
        viewer.onClose = { [weak self, weak viewer] in self?.recordWindows.removeAll { $0 === viewer } }
        viewer.showWindow(nil); viewer.window?.makeKeyAndOrderFront(nil)
    }
    private func showText(_ title: String, _ text: String) {
        let alert = PopupAlert(); alert.messageText = title; alert.addButton(withTitle: "关闭")
        let (scroll, editor) = textEditor(text, editable: false); scroll.frame = NSRect(x: 0, y: 0, width: 680, height: 400); alert.accessoryView = scroll; editor.isSelectable = true; alert.runModal()
    }
    private func newConversation() {
        diagnostic?.cancel("新建对话，只读授权已撤销。")
        guard session?.busy != true else { status.stringValue = "请先停止当前生成。"; return }
        guard let pane else {
            AIHistory.shared.remember(standalone)
            standalone = AIAssistantSession(target: AITarget(paneID: UUID(), stamp: "standalone", title: "独立对话（未绑定终端）", metadata: ""))
            session = standalone; render(); return
        }
        if let prior = pane.aiSession { AIHistory.shared.remember(prior) }
        pane.aiSession = AIAssistantSession(target: pane.aiTarget); bind(pane, force: true)
    }
    private func showHistory() {
        diagnostic?.cancel("打开历史，只读授权已撤销。")
        let alert = PopupAlert(); alert.messageText = "AI 对话历史"
        alert.informativeText = "搜索和预览仅在本机进行。继续对话后，首次发送时确认是否携带历史上下文。"
        let resume = alert.addButton(withTitle: "继续对话"); resume.identifier = .init("ai.history.resume")
        let open = alert.addButton(withTitle: "只读查看"); open.identifier = .init("ai.history.open")
        alert.addButton(withTitle: "取消")
        let browser = AIHistoryBrowser(open: open, resume: resume, canResume: !standalone.busy)
        alert.accessoryView = browser
        defer { browser.dispose(); alert.accessoryView = nil }
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn || result == .alertSecondButtonReturn,
              let selected = browser.selected, let entry = AIHistory.shared.entries.first(where: { $0.id == selected.id }) else { return }
        session = AIAssistantSession(archive: entry)
        if result == .alertFirstButtonReturn { continueArchivedConversation() } else { render() }
    }
    func makeMoreMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ id: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.identifier = .init(id); item.isEnabled = enabled; menu.addItem(item)
        }
        if session?.archived == true { add("继续此历史对话", "ai.history.continue", #selector(continueArchivedConversation), enabled: !standalone.busy) }
        add("绑定这段对话到当前 SSH…", "ai.history.bindCurrent", #selector(bindHistoryToCurrentSSH), enabled: canBindHistoryToCurrentSSH)
        add("切回当前终端会话", "ai.current", #selector(returnToTerminal), enabled: workspace?.selectedPaneForAI != nil)
        if session !== standalone { add(standalone.unread ? "返回独立对话 · 新回复" : "返回独立对话", "ai.history.return", #selector(showIndependentConversation)) }
        menu.addItem(.separator())
        add(diagnostic?.active == true ? "停止 SSH 任务" : "开始 SSH 任务…", "ai.diagnose", #selector(toggleDiagnostics), enabled: diagnostic?.active == true || (pane?.canRunAIDiagnostics == true && session?.busy == false && session?.archived == false))
        menu.addItem(.separator())
        add("选择额外资料并发送…", "ai.send.review", #selector(reviewAndSend), enabled: session != nil && session?.busy != true && session?.archived != true)
        add("查看 / 导出处理记录…", "ai.record", #selector(showRecord), enabled: session?.messages.isEmpty == false)
        add("清空后续可引用的历史", "ai.history.clear", #selector(clearReusableHistory), enabled: session != nil && session?.busy != true && session?.archived != true)
        menu.addItem(.separator())
        add("在独立窗口中打开", "ai.detach", #selector(openDetached))
        return menu
    }
    @objc private func toggleDiagnostics() {
        if diagnostic?.active == true { stopGenerating(); return }
        startDiagnostics(automaticRouting: false)
    }
    private func confirmDiagnosticTarget(_ pane: TerminalPane) -> Bool {
        guard let prompt = pane.aiInteractivePrompt else {
            status.stringValue = "当前终端未确认处于空闲 Shell。请处理密码提示、退出交互程序并清空未提交内容后继续。"
            return false
        }
        if pane.aiCanFill && !pane.aiTerminalNeedsConfirmation && !pane.aiTerminalCommandRunning { return true }
        let version = pane.aiUserInputVersion, epoch = pane.aiContextEpoch
        let alert = PopupAlert(); alert.messageText = "确认在当前终端执行"
        alert.informativeText = "目标标签：" + pane.title + "\n当前提示符：" + prompt + "\n\n命令会直接输入此终端并回车，跟随你已完成的多层 SSH、用户切换及当前目录，不会在初始登录主机另开执行通道。请确认这里是空闲的 Bash/Zsh/sh 命令行，未在输入密码或运行交互程序。"
        let approve = alert.addButton(withTitle: "确认当前是空闲 Shell"); approve.identifier = .init("ai.diagnose.approve"); approve.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "取消"); cancel.identifier = .init("ai.diagnose.defer"); cancel.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn, pane.aiUserInputVersion == version, pane.aiContextEpoch == epoch, pane.aiInteractivePrompt == prompt else { return false }
        return pane.confirmAIInteractiveReady()
    }
    private func startDiagnostics(automaticRouting: Bool) {
        guard let pane, let session, !session.busy, !session.archived, pane.canRunAIDiagnostics else { return }
        do {
            let target = pane.aiTarget, settings = try session.requestSettings(from: AISettings.load())
            if !automaticRouting && !confirmDiagnosticTarget(pane) { return }
            guard self.session === session, self.pane === pane, pane.aiTarget == target, !session.busy,
                  (try session.requestSettings(from: AISettings.load())) == settings else { return }
            let queries = AIReadOnlyQuery.automaticQueries(problem: session.draft)
            let run = try AIDiagnosticRun(pane: pane, session: session, settings: settings, queries: queries, allowsDirectAnswer: automaticRouting)
            diagnostic?.cancel("已开始新的排查任务。")
            do {
                run.confirmExecutionTarget = { [weak self, weak pane, weak session] in
                    guard let self, let pane, let session, self.session === session, self.pane === pane else { return false }
                    return self.confirmDiagnosticTarget(pane)
                }
            }
            diagnostic = run; run.onChange = { [weak self, weak run] in
                guard let self, let run, run.belongs(to: self.session) else { return }
                self.render()
            }
            run.onResultsReady = { [weak run, weak session] in
                guard let run, run.active, !run.paused, let session else { return }
                do { try session.sendDiagnosticContext(target: { [weak run] in run?.requestTarget }, failed: { [weak run] error in run?.pause("自动回传失败：" + error.localizedDescription) }) }
                catch { run.pause("自动回传失败：" + error.localizedDescription) }
            }
            run.approveOperation = { [weak pane, weak run] query, canGrantReadOnly in
                guard let pane, let run, !pane.isShutdown, run.requestTarget != nil else { return .deny }
                let alert = PopupAlert(); alert.messageText = query.isMutation ? "ask · 审批 SSH 变更" : "ask · 审批 SSH 查询"
                alert.informativeText = "目标：\(target.title)\n执行位置：目标标签的当前交互终端\n当前提示符：\(pane.aiInteractivePrompt ?? "未确认")\n原因：\(run.operationReason)\n" + (query.isMutation ? "此操作可能创建、修改、删除文件或改变服务状态；只读授权不会放行。" : "本次命令边界内的终端输出将发送给当前模型；后台程序输出可能混入。") + "\n接收方：\(settings.channelName ?? settings.provider.title) · \(settings.model)\n仅批准下方这一项，不批准后续变更。"
                let (scroll, _) = textEditor(query.command, editable: false)
                scroll.frame = NSRect(x: 0, y: 0, width: 660, height: 220); alert.accessoryView = scroll
                let once = alert.addButton(withTitle: "批准这一次"); once.identifier = .init("ai.ssh.approveOnce"); once.keyEquivalent = ""
                let deny = alert.addButton(withTitle: "拒绝"); deny.identifier = .init("ai.ssh.deny"); deny.keyEquivalent = "\r"
                if canGrantReadOnly { alert.addButton(withTitle: "本任务安全只读自动批准").identifier = .init("ai.ssh.approveReadOnly") }
                switch alert.runModal() {
                case .alertFirstButtonReturn: return .once
                case .alertThirdButtonReturn where canGrantReadOnly: return .readOnlyForTask
                default: return .deny
                }
            }
            run.onUncertainPlan = { reason in
                let alert = PopupAlert(); alert.messageText = "操作已拒绝"
                alert.informativeText = reason + "\n任务已暂停。请补充具体信息或调整方案后继续；极端危险命令无法通过审批放行；不支持的命令也不会执行。"
                alert.addButton(withTitle: "我来检查"); alert.runModal()
            }
            session.setTaskInstruction(run.instruction)
            if session.draft.isEmpty { session.draft = "请先询问故障现象，再按需选择已授权的只读查询，依据返回结果逐步排查。" }
            render()
        } catch { status.stringValue = error.localizedDescription }
    }
    private func resumeDiagnostics() {
        guard let run = diagnostic, run.paused, run.belongs(to: session), let pane else { return }
        let alert = PopupAlert(); alert.messageText = "继续原排查任务"
        alert.informativeText = "继续在绑定的当前终端输入并执行命令，保留原任务证据和预算。接管后需重新确认终端状态与授权；若已切换主机或用户，请新建任务。"
        alert.addButton(withTitle: "继续排查").identifier = .init("ai.diagnose.resume")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn, self.pane === pane else { return }
        do { try run.resume() } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showApprovalMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.font = AIComposerTypography.controlFont
        let active = diagnostic?.active == true && diagnostic?.belongs(to: session) == true
        if active {
            let item = NSMenuItem(title: diagnostic?.readOnlyAuthorized == true ? "本任务改为逐次审批" : "本任务只读授权可在下一次 ask 中确认", action: #selector(revokeTaskReadOnly), keyEquivalent: "")
            item.target = self; item.isEnabled = diagnostic?.readOnlyAuthorized == true; menu.addItem(item); menu.addItem(.separator())
        }
        let mode = (try? AISettings.load().permissions) ?? .ask
        for (index, modeChoice) in AIPermissionMode.allCases.enumerated() {
            let title = modeChoice.title + " · " + modeChoice.explanation
            let item = NSMenuItem(title: title, action: #selector(changeGlobalApproval(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = mode == modeChoice ? .on : .off
            item.isEnabled = !active && session?.busy != true; menu.addItem(item)
        }
        let info = NSMenuItem(title: "危险命令在所有权限模式下均拒绝", action: nil, keyEquivalent: ""); info.isEnabled = false; menu.addItem(info)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: approval.bounds.minY), in: approval)
    }
    @objc private func revokeTaskReadOnly() {
        guard let diagnostic, diagnostic.active, diagnostic.belongs(to: session) else { return }
        diagnostic.revokeReadOnlyAuthorization(); render()
    }
    @objc private func changeGlobalApproval(_ sender: NSMenuItem) {
        guard session?.busy != true, diagnostic?.active != true else { status.stringValue = "请先结束当前任务，再修改全局审批设置。"; return }
        do { var settings = try AISettings.load(); settings.permissionMode = AIPermissionMode.allCases[sender.tag]; settings.autoApproveReadOnly = settings.permissions == .assist; try settings.save(); render() }
        catch { status.stringValue = error.localizedDescription }
    }
    private func showMore() {
        guard let button = moreButton else { return }
        makeMoreMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }
    private var canBindHistoryToCurrentSSH: Bool {
        guard let source = session, !source.busy, source.archived || source === standalone,
              let destination = workspace?.selectedPaneForAI else { return false }
        return destination.canRunAIDiagnostics && destination.aiSession?.busy != true
    }
    @objc private func bindHistoryToCurrentSSH() {
        guard canBindHistoryToCurrentSSH, let workspace, let source = session,
              let destination = workspace.selectedPaneForAI else { return }
        let target = destination.aiTarget, revision = source.revision, previous = destination.aiSession
        let processID = destination.terminal.process.shellPid, epoch = destination.aiContextEpoch
        let alert = PopupAlert(); alert.messageText = "绑定历史对话到当前 SSH？"
        alert.informativeText = "目标：" + target.title + "\n原始连接（仅标识标签）：\(destination.profile.username)@\(destination.profile.host):\(destination.profile.port)\n命令将在当前终端执行，跟随多层跳转；当前提示符：\(destination.aiInteractivePrompt ?? "未确认")\n\n将创建这段对话的续聊副本，保留原历史。当前终端原有 AI 对话按历史保存设置保存。历史结果仅供参考，不代表当前机器状态；不会恢复旧任务或旧审批，也不会立即发送内容或执行命令。首次发送需确认历史上下文，之后遵循当前 ask/只读授权设置。"
        let approve = alert.addButton(withTitle: "确认绑定"); approve.identifier = .init("ai.history.bind.approve"); approve.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "取消"); cancel.identifier = .init("ai.history.bind.cancel"); cancel.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard self.session === source, source.revision == revision, !source.busy,
              workspace.selectedPaneForAI === destination, destination.canRunAIDiagnostics,
              destination.terminal.process.shellPid == processID, destination.aiContextEpoch == epoch, destination.aiTarget == target,
              destination.aiSession === previous, previous?.busy != true else {
            status.stringValue = "确认期间对话或 SSH 目标发生变化，未绑定。请重新确认。"; return
        }
        do {
            let continued = try source.continuation(boundTo: target)
            diagnostic?.cancel("绑定历史对话，原任务授权已撤销。"); diagnostic = nil
            if let previous { AIHistory.shared.remember(previous) }
            AIHistory.shared.remember(source)
            destination.aiSession = continued
            showingIndependent = false; pane = destination; session = continued
            AIHistory.shared.remember(continued); render(); window?.makeFirstResponder(editor)
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func returnToTerminal() { bind(workspace?.selectedPaneForAI, force: true) }
    @objc private func clearReusableHistory() { session?.clearSendHistory() }
    @objc private func openDetached() { detach() }
    @objc private func continueArchivedConversation() {
        guard !standalone.busy, let session, session.archived else { return }
        do {
            let continued = try session.continuingHistory()
            AIHistory.shared.remember(standalone); standalone = continued
            AIHistory.shared.remember(continued); showIndependentConversation()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showIndependentConversation() {
        diagnostic?.cancel("切换对话，只读授权已撤销。")
        showingIndependent = true; pane = nil; session = standalone; render(); window?.makeFirstResponder(editor)
    }
    @objc private func showRecord() {
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
    private func codeCard(language: String, source: String, closed: Bool, session: AIAssistantSession, allowCommand: Bool) -> NSView {
        let code = AIMarkdownTextView(NSAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]))
        code.identifier = .init("ai.markdown.code")
        let languageLabel = label(language.isEmpty ? "代码" : String(language.prefix(40)), font: .systemFont(ofSize: 10, weight: .medium)); languageLabel.textColor = .secondaryLabelColor
        let copy = AIActionButton("复制代码") { [weak self] in self?.copy(source) }; copy.identifier = .init("ai.code.copy")
        let buttons = NSStackView(views: [copy]); buttons.spacing = 4
        let block = NSStackView(views: [languageLabel, code]); block.orientation = .vertical; block.alignment = .leading; block.spacing = 6
        if closed, allowCommand, AICommand.isShell(language), !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let command = AICommand(text: source.trimmingCharacters(in: .whitespacesAndNewlines))
            let refusal = (try? AISSHCommandPolicy.parse(command.text)) == nil
            let note = label(refusal ? "此命令不支持安全填入或属于禁止操作；不会向 SSH 发送。" : command.impact, font: .systemFont(ofSize: 10)); note.textColor = .secondaryLabelColor
            block.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
            let fill = AIActionButton("填入原会话") { [weak self, weak session] in
                guard let self, let session, !session.archived else { return }
                do { if try self.workspace?.fillAICommand(command, target: session.target, confirmIfNeeded: true) == true { self.status.stringValue = "已填入原会话，尚未回车执行。" } } catch { self.status.stringValue = error.localizedDescription }
            }
            fill.identifier = .init("ai.command.fill"); fill.isEnabled = !session.archived && session !== standalone && command.canFill
            fill.toolTip = "每次 ask 批准后仅填入原会话，不回车、不广播；禁止操作无法填入。"
            buttons.addArrangedSubview(fill)
            buttons.addArrangedSubview(AIActionButton("存为快速命令") { [weak self] in self?.workspace?.saveAICommand(command) })
        }
        block.addArrangedSubview(buttons); code.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return AICommandCard(content: block)
    }
    func render() {
        guard !rendering else { return }
        rendering = true; defer { rendering = false }; clear(messages); clear(attachmentsStack)
        receiptView?.update(session?.sendReceipts ?? [])
        if window?.isVisible == true && !isHiddenOrHasHiddenAncestor { session?.markRead() }
        let settings = try? AISettings.load()
        refreshModelPicker(settings)
        historyBinding.isHidden = !(session?.archived == true || session === standalone)
        historyBinding.isEnabled = canBindHistoryToCurrentSSH
        historyBinding.toolTip = "先选中已连接的 SSH 标签；绑定会创建续聊副本，不恢复旧任务授权。"
        target.stringValue = session.map { "当前：" + $0.target.title + ($0.archived ? " · 历史只读" : "") } ?? "选择一个终端会话后开始分析"
        target.toolTip = "仅标识本机目标，不会自动发送。\n" + (session?.target.metadata ?? "")
        status.toolTip = session?.lastReceipt
        editor.string = session?.draft ?? ""; editor.needsDisplay = true
        editor.isEditable = session != nil && session?.busy != true && session?.archived != true
        composer.setEditingEnabled(editor.isEditable)
        canSendDraft = editor.isEditable && (session.flatMap { active in settings.flatMap { try? active.requestSettings(from: $0) } } != nil)
        send.isEnabled = canSendDraft; stop.isEnabled = session?.busy == true
        let working = session?.busy == true || (diagnostic?.active == true && diagnostic?.paused == false && diagnostic?.belongs(to: session) == true)
        stop.toolTip = "停止当前任务并接管 · Ctrl+C 或双击 Esc · 保留对话上下文"
        stop.isHidden = !working; send.isHidden = working; stop.isEnabled = working
        send.isEnabled = send.isEnabled && !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.needsDisplay = true; stop.needsDisplay = true
        let mode = diagnostic?.active == true && diagnostic?.belongs(to: session) == true ? diagnostic!.permissionMode : (settings?.permissions ?? .ask)
        approval.title = mode.title
        approval.toolTip = mode.explanation
        contextStatus.stringValue = session?.contextUsageLabel ?? ""; contextStatus.isHidden = contextStatus.stringValue.isEmpty
        status.stringValue = session?.status.isEmpty == false ? session!.status : "直接提问，自动处理聊天、命令辅助和持续排查。"
        if settings?.modelChoices.isEmpty != false {
            add(label("先配置 AI 服务\n填写接口地址、模型和密钥，然后测试连接。"), to: messages)
            add(AIActionButton("配置 AI 服务") { [weak self] in self?.workspace?.showAISettings() }, to: messages)
        } else if session?.messages.isEmpty != false { add(label("选中报错后右键“用 AI 分析”；或选择上方入口，描述目标、范围和限制。"), to: messages) }
        if let session {
            if session.messages.count > 12 { add(label("此处显示最近 12 条消息；处理记录可查看完整内容。"), to: messages) }
            for message in session.messages.suffix(12) {
                let card = AIMessageView(assistant: message.role == "assistant")
                if message.role == "assistant" {
                    if let model = message.modelLabel {
                        let origin = label(model, font: .systemFont(ofSize: 10)); origin.textColor = .secondaryLabelColor; origin.identifier = .init("ai.response.model"); card.append(origin)
                    }
                    var codeCount = 0
                    for block in AIMarkdown.blocks(AIMarkdown.readableProse(String((message.displayText ?? message.text).prefix(12000)))) {
                        switch block {
                        case let .text(text): card.append(AIMarkdownTextView(text))
                        case let .code(language, source, closed):
                            if language.lowercased() == "oshell-query", closed {
                                let queries = try? AIReadOnlyQuery.requested(in: "```oshell-query\n" + source + "\n```", allowed: nil)
                                card.append(label(queries.map { "建议查询：" + $0.map(\.title).joined(separator: "、") } ?? "查询计划超出允许范围，未执行。"))
                            } else if language.lowercased() == "oshell-plan", closed {
                                if let plan = try? AIInvestigationPlan.parse("```oshell-plan\n" + source + "\n```") {
                                    card.append(label(plan.summary))
                                    if !plan.queries.isEmpty { card.append(label("下一步：" + plan.queries.compactMap(AIReadOnlyQuery.init(rawValue:)).map(\.title).joined(separator: "、"))) }
                                    if !plan.reason.isEmpty { card.append(label(plan.reason, font: .systemFont(ofSize: 11))) }
                                    if !plan.evidence.isEmpty { card.append(label("依据：" + plan.evidence.joined(separator: "、"), font: .systemFont(ofSize: 11))) }
                                } else { card.append(label("排查计划未通过校验，未执行。")) }
                            } else { card.append(codeCard(language: language, source: source, closed: closed, session: session, allowCommand: codeCount < 12)); codeCount += 1 }
                        }
                    }
                    if message.text.count > 12000 { card.append(label("…完整内容见处理记录")) }
                } else {
                    let displayed = message.displayText ?? message.text
                    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
                    let text = NSAttributedString(string: String(displayed.prefix(12000)) + (displayed.count > 12000 ? "\n…完整内容见处理记录" : ""), attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
                    let body = AIMarkdownTextView(text); body.identifier = .init("ai.message.userText"); card.append(body)
                }
                if !message.images.isEmpty {
                    let attachments = label("图片附件：" + message.images.map(\.name).joined(separator: "、"), font: .systemFont(ofSize: 11)); attachments.textColor = .secondaryLabelColor
                    card.append(attachments)
                }
                add(card, to: messages)
            }
            if session.busy && !session.collectingDiagnostics {
                let card = AIMessageView(assistant: true); card.identifier = .init("ai.message.pending")
                let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small; spinner.isIndeterminate = true
                spinner.startAnimation(nil)
                let hint = label(session.compacting ? "正在压缩上下文，保留目标与关键证据…" : session.collectingDiagnostics ? "正在执行已授权的操作…" : session.streamingText.isEmpty ? "正在思考，等待回复…" : "正在生成回复…", font: .systemFont(ofSize: 12))
                card.append(NSStackView(views: [spinner, hint]))
                if !session.streamingText.isEmpty {
                    // Partial output is selectable plain text, never actionable code.
                    let text = AIMarkdownTextView(NSAttributedString(string: session.streamingText, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
                    text.identifier = .init("ai.message.streaming"); card.append(text)
                }
                add(card, to: messages)
            }
            if let diagnostic, diagnostic.belongs(to: session) {
                let title = diagnostic.completed ? "终端任务 · 已完成" : diagnostic.paused ? "终端任务 · 已暂停" : diagnostic.active ? "终端任务 · 进行中" : "终端任务 · 已停止"
                let card = AITaskStatusView(title: title, state: diagnostic.completed ? .completed : diagnostic.paused ? .paused : diagnostic.active ? .active : .stopped)
                if diagnostic.active {
                    let permission = label(diagnostic.permissionMode.title + " · " + diagnostic.permissionMode.explanation, font: .systemFont(ofSize: 11))
                    permission.textColor = .secondaryLabelColor; card.append(permission)
                    card.append(label(diagnostic.displayStatus, font: .systemFont(ofSize: 12)))
                } else if !diagnostic.completed { card.append(label(diagnostic.displayStatus, font: .systemFont(ofSize: 12))) }
                var details: [NSButton] = [AIActionButton("查看操作记录") { [weak self, weak diagnostic] in self?.showRecords("操作记录", entries: [(diagnostic?.log ?? "") + "\n\n" + (diagnostic?.progress ?? "")]) }]
                if !diagnostic.records.isEmpty { details.append(AIActionButton("查看查询结果") { [weak self, weak diagnostic] in self?.showRecords("查询结果", entries: diagnostic?.records ?? []) }) }
                card.appendActions(details)
                var controls = [NSButton]()
                if diagnostic.paused { controls.append(AIActionButton("继续原任务") { [weak self] in self?.resumeDiagnostics() }) }
                if let pane, diagnostic.restartQuestion(for: pane, conversation: session) != nil {
                    let restart = AIActionButton("重新开始原任务") { [weak self] in
                        guard let self else { return }; self.editor.string = "继续任务"; self.performSend(review: false)
                    }
                    restart.identifier = .init("ai.diagnose.restart"); controls.append(restart)
                }
                if diagnostic.active { controls.append(AIActionButton("停止并接管终端") { [weak self] in self?.stopGenerating() }) }
                card.appendActions(controls)
                if diagnostic.active && diagnostic.readOnlyAuthorized {
                    card.appendActions([AIActionButton("本任务改为每次 ask") { [weak diagnostic] in diagnostic?.revokeReadOnlyAuthorization() }])
                }
                add(card, to: messages)
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
        composer.attachmentsHeight = min(90, CGFloat(attachmentsStack.arrangedSubviews.count) * 30)
        transcript.needsLayout = true; attachmentsScroll.needsLayout = true
        needsLayout = true; layoutSubtreeIfNeeded()
        transcript.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - transcript.contentSize.height))); transcript.reflectScrolledClipView(transcript.contentView)
    }
}
