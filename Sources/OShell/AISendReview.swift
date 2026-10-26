// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Explicitly sizes the read-only document after wrapping. A review must expose
/// the entire payload, including its final line, even when the window is resized.
private final class AIRequestPreview: NSScrollView {
    var resetToTop = true
    let text = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: nil)
    init() {
        super.init(frame: .zero)
        text.isEditable = false; text.isSelectable = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]; text.textContainerInset = NSSize(width: 8, height: 8)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.textContainer?.widthTracksTextView = true
        documentView = text; hasVerticalScroller = true; borderType = .bezelBorder
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // NSAlert may resize its accessory after its first layout. Reset only
        // once on presentation, after that resize, without fighting user scrolling.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.resetToTop = true; self.needsLayout = true; self.layoutSubtreeIfNeeded()
            self.contentView.scroll(to: .zero); self.reflectScrolledClipView(self.contentView)
        }
    }
    override func layout() {
        super.layout()
        let width = max(1, contentSize.width)
        text.setFrameSize(NSSize(width: width, height: max(contentSize.height, text.frame.height)))
        guard let container = text.textContainer, let manager = text.layoutManager else { return }
        container.containerSize = NSSize(width: max(1, width - 2 * text.textContainerInset.width), height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(contentSize.height, ceil(manager.usedRect(for: container).maxY) + 2 * text.textContainerInset.height)
        if abs(text.frame.height - height) > 0.5 { text.setFrameSize(NSSize(width: width, height: height)) }
        if resetToTop { contentView.scroll(to: .zero); reflectScrolledClipView(contentView); resetToTop = false }
    }
}

/// This UI only builds local snapshots. The final alert button is the sole user
/// approval; checking a field, opening an image or cancelling never sends data.
final class AISendReview: InterfaceSurfaceView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private final class Action: NSButton {
        var run: (() -> Void)?
        convenience init(_ title: String, checkbox: Bool = false, run: @escaping () -> Void) {
            self.init(title: title, target: nil, action: nil); self.run = run
            if checkbox { setButtonType(.switch) } else { bezelStyle = .rounded; controlSize = .small }
            target = self; action = #selector(click)
        }
        @objc private func click() { run?() }
    }
    private let settings: AISettings
    private var draft: AISendDraft
    private var selected: Set<String>
    private let preview: NSTextView
    private let textScroll: AIRequestPreview
    private let imageScroll = NSScrollView()
    private let technical = NSButton(checkboxWithTitle: "技术详情", target: nil, action: nil)
    override var isFlipped: Bool { true }
    private let choices = NSStackView(), images = NSStackView(), summary = NSTextField(wrappingLabelWithString: "")
    private let list = NSScrollView(), document = Document()
    private weak var approveButton: NSButton?
    private let revoke: ((String) -> AISendDraft?)?
    private(set) var snapshot: AIRequest?
    init(draft: AISendDraft, settings: AISettings, approveButton: NSButton, revoke: ((String) -> AISendDraft?)? = nil) {
        self.draft = draft; self.settings = settings; selected = draft.defaults; self.approveButton = approveButton; self.revoke = revoke
        textScroll = AIRequestPreview(); preview = textScroll.text
        let height = min(520, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 260))
        super.init(frame: NSRect(x: 0, y: 0, width: min(760, max(520, (NSScreen.main?.visibleFrame.width ?? 900) - 64)), height: height))
        identifier = .init("ai.sendReview")
        list.drawsBackground = true; list.backgroundColor = .windowBackgroundColor; list.identifier = .init("ai.review.sources"); list.documentView = document; list.hasVerticalScroller = true; list.autohidesScrollers = true
        choices.orientation = .vertical; choices.alignment = .leading; choices.spacing = 8; choices.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(choices)
        NSLayoutConstraint.activate([choices.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4), choices.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8), choices.topAnchor.constraint(equalTo: document.topAnchor, constant: 4)])
        preview.isSelectable = true; preview.identifier = .init("ai.review.payload")
        preview.font = .systemFont(ofSize: 13)
        images.spacing = 6; images.alignment = .top; images.orientation = .horizontal
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor
        imageScroll.documentView = images; imageScroll.hasHorizontalScroller = true; imageScroll.autohidesScrollers = false
        imageScroll.drawsBackground = false; imageScroll.identifier = .init("ai.review.images")
        textScroll.identifier = .init("ai.review.previewScroll")
        technical.target = self; technical.action = #selector(toggleTechnical)
        technical.identifier = .init("ai.review.technical")
        technical.toolTip = "可选：查看接口参数、JSON 请求与摘要；切换不会发送或改变所选内容。"
        for view in [list, summary, textScroll, imageScroll, technical] { addSubview(view) }
        rebuildChoices(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func add(_ view: NSView) { choices.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: choices.widthAnchor).isActive = true }
    private func rebuildChoices() {
        choices.arrangedSubviews.forEach { choices.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (origin, title) in [(AIDisclosure.Origin.current, "本次问题和主动添加的附件"), (.identity, "会话信息 · 默认不发送"), (.history, "历史资料 · 默认不重发")] {
            let items = draft.items.filter { $0.origin == origin }
            guard !items.isEmpty else { continue }
            let heading = NSTextField(wrappingLabelWithString: title); heading.font = .systemFont(ofSize: 12, weight: .semibold); add(heading)
            for item in items {
                let button = Action(String(item.name.prefix(36)), checkbox: true) { [weak self] in
                    guard let self else { return }
                    if self.selected.contains(item.id) { self.selected.remove(item.id) } else { self.selected.insert(item.id) }
                    self.refresh()
                }
                button.identifier = .init("ai.review.item." + item.id); button.state = selected.contains(item.id) ? .on : .off
                button.isEnabled = item.id != draft.requiredID
                button.font = .systemFont(ofSize: 11); button.lineBreakMode = .byTruncatingTail; button.toolTip = item.name + "\n" + (item.image == nil ? String(item.text.prefix(500)) : "图片须在右侧预览后授权")
                add(button)
                if !item.dependencies.isEmpty {
                    let names = draft.items.filter { item.dependencies.contains($0.id) }.map(\.name)
                    let note = NSTextField(wrappingLabelWithString: "依据：" + names.joined(separator: "、")); note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor; add(note)
                }
                if item.origin == .history, revoke != nil {
                    let remove = Action("后续不再引用此项") { [weak self] in
                        guard let self, let revised = self.revoke?(item.id) else { return }
                        self.draft = revised; self.selected.formIntersection(Set(revised.items.map(\.id)))
                        self.selected.insert(revised.requiredID); self.rebuildChoices(); self.refresh()
                    }
                    remove.identifier = .init("ai.review.revoke." + item.id); add(remove)
                }
            }
        }
        needsLayout = true
    }
    private func refresh() {
        images.arrangedSubviews.forEach { images.removeArrangedSubview($0); $0.removeFromSuperview() }
        do {
            let frozen = try draft.freeze(settings: settings, selected: selected); snapshot = frozen
            displaySnapshot()
            summary.stringValue = "将发送 \(frozen.items.count) 项内容 · 图片 \(frozen.items.compactMap(\.image).count) 张\n请检查下方文字和图片，取消勾选即可排除。"
            for image in frozen.items.compactMap(\.image) {
                let thumbnail = NSImageView(); thumbnail.image = NSImage(data: image.png); thumbnail.imageScaling = .scaleProportionallyUpOrDown
                thumbnail.widthAnchor.constraint(equalToConstant: 98).isActive = true; thumbnail.heightAnchor.constraint(equalToConstant: 60).isActive = true
                let view = Action("查看图片") {
                    let alert = PopupAlert(); alert.messageText = image.name; alert.addButton(withTitle: "关闭")
                    let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 640, height: 420)); imageView.image = NSImage(data: image.png); imageView.imageScaling = .scaleProportionallyUpOrDown
                    alert.accessoryView = imageView; alert.runModal()
                }
                let column = NSStackView(views: [thumbnail, view]); column.orientation = .vertical; column.spacing = 2; images.addArrangedSubview(column)
            }
            approveButton?.isEnabled = true
        } catch { snapshot = nil; preview.string = error.localizedDescription; textScroll.resetToTop = true; textScroll.needsLayout = true; summary.stringValue = "尚不能发送；请调整左侧范围。"; approveButton?.isEnabled = false }
        needsLayout = true
    }
    @objc private func toggleTechnical() { displaySnapshot() }
    private func displaySnapshot() {
        guard let snapshot else { return }
        preview.font = technical.state == .on ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 13)
        preview.string = technical.state == .on ? snapshot.preview : snapshot.disclosureText
        textScroll.resetToTop = true; textScroll.needsLayout = true; needsLayout = true
    }
    override func layout() {
        super.layout()
        let leftWidth = min(260, max(180, bounds.width * 0.34)), gap: CGFloat = 12
        let rightX = leftWidth + gap, rightWidth = max(1, bounds.width - rightX)
        technical.frame = NSRect(x: 4, y: bounds.height - 24, width: leftWidth - 8, height: 24)
        list.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height - 32); list.tile()
        // Resolve the document width before fitting its wrapping labels. Repeat
        // after height changes so flipped coordinates are correct on first display.
        for _ in 0..<3 {
            document.setFrameSize(NSSize(width: list.contentSize.width, height: max(1, document.frame.height)))
            document.layoutSubtreeIfNeeded()
            let height = max(list.contentSize.height, choices.fittingSize.height + 8)
            document.setFrameSize(NSSize(width: list.contentSize.width, height: height))
            document.layoutSubtreeIfNeeded(); list.tile()
        }
        let summaryHeight = max(40, ceil(summary.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: rightWidth, height: 1000)).height ?? 40))
        summary.frame = NSRect(x: rightX, y: 0, width: rightWidth, height: summaryHeight)
        let imageHeight: CGFloat = images.arrangedSubviews.isEmpty ? 0 : 104
        imageScroll.isHidden = imageHeight == 0
        imageScroll.frame = NSRect(x: rightX, y: bounds.height - imageHeight, width: rightWidth, height: imageHeight)
        images.setFrameSize(NSSize(width: max(rightWidth, images.fittingSize.width), height: 84)); images.layoutSubtreeIfNeeded()
        textScroll.frame = NSRect(x: rightX, y: summaryHeight + 8, width: rightWidth, height: max(80, bounds.height - summaryHeight - 8 - imageHeight - (imageHeight > 0 ? 8 : 0)))
        textScroll.needsLayout = true; textScroll.layoutSubtreeIfNeeded()
    }
    static func review(draft: AISendDraft, settings: AISettings, revoke: ((String) -> AISendDraft?)? = nil) -> AIRequest? {
        let alert = PopupAlert(); alert.messageText = "授权本次 AI 发送"
        alert.informativeText = "勾选允许发送的资料，右侧显示实际发送内容。确认后仅发送这一次，不执行任何命令。"
        let send = alert.addButton(withTitle: "授权并发送一次"); send.identifier = .init("ai.review.approve")
        // Return must not accidentally authorize while reviewing; require a click.
        send.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "取消"); cancel.identifier = .init("ai.review.cancel")
        let view = AISendReview(draft: draft, settings: settings, approveButton: send, revoke: revoke)
        alert.accessoryView = view
        return alert.runModal() == .alertFirstButtonReturn ? view.snapshot : nil
    }
    static func reviewTest(_ snapshot: AIRequest) -> Bool {
        let alert = PopupAlert(); alert.messageText = "授权连接测试"
        alert.informativeText = "只向下列接口发送固定测试文字与助手规则，不附带会话、历史或图片。"
        let button = alert.addButton(withTitle: "授权并测试一次"); button.identifier = .init("ai.test.approve"); button.keyEquivalent = ""
        alert.addButton(withTitle: "取消")
        let scroll = AIRequestPreview(); scroll.text.font = .systemFont(ofSize: 13); scroll.text.string = snapshot.disclosureText
        let details = Action("技术详情", checkbox: true) {}
        details.identifier = .init("ai.test.technical")
        details.run = { [weak details, weak scroll] in
            guard let details, let scroll else { return }
            scroll.text.font = details.state == .on ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 13)
            scroll.text.string = details.state == .on ? snapshot.preview : snapshot.disclosureText
            scroll.resetToTop = true; scroll.needsLayout = true
        }
        let content = InterfaceSurfaceView(frame: NSRect(x: 0, y: 0, width: 680, height: 370))
        details.frame = NSRect(x: 0, y: 0, width: 150, height: 24)
        scroll.frame = NSRect(x: 0, y: 30, width: 680, height: 340)
        content.addSubview(scroll); content.addSubview(details); alert.accessoryView = content
        return alert.runModal() == .alertFirstButtonReturn
    }
}
