// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Explicitly sizes the read-only document after wrapping. A review must expose
/// the entire payload, including its final line, even when the window is resized.
private final class AIRequestPreview: NSScrollView {
    let text = CommandTextView(frame: .zero, textContainer: nil)
    init() {
        super.init(frame: .zero)
        text.isEditable = false; text.isSelectable = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]; text.textContainerInset = NSSize(width: 8, height: 8)
        text.font = .oshellMonospacedSystemFont(ofSize: 11, weight: .regular)
        documentView = text; hasVerticalScroller = true; borderType = .bezelBorder
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width = max(1, contentSize.width)
        text.setFrameSize(NSSize(width: width, height: max(contentSize.height, text.frame.height)))
        guard let container = text.textContainer, let manager = text.layoutManager else { return }
        container.containerSize = NSSize(width: max(1, width - 2 * text.textContainerInset.width), height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(contentSize.height, ceil(manager.usedRect(for: container).maxY) + 2 * text.textContainerInset.height)
        if abs(text.frame.height - height) > 0.5 { text.setFrameSize(NSSize(width: width, height: height)) }
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
    private let choices = NSStackView(), images = NSStackView(), summary = NSTextField(wrappingLabelWithString: "")
    private let list = NSScrollView(), document = Document()
    private weak var approveButton: NSButton?
    private let revoke: ((String) -> AISendDraft?)?
    private(set) var snapshot: AIRequest?
    init(draft: AISendDraft, settings: AISettings, approveButton: NSButton, revoke: ((String) -> AISendDraft?)? = nil) {
        self.draft = draft; self.settings = settings; selected = draft.defaults; self.approveButton = approveButton; self.revoke = revoke
        let textScroll = AIRequestPreview(); preview = textScroll.text
        let height = min(520, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 260))
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: height))
        identifier = .init("ai.sendReview")
        list.drawsBackground = false; list.documentView = document; list.hasVerticalScroller = true; list.autohidesScrollers = true
        choices.orientation = .vertical; choices.alignment = .leading; choices.spacing = 8; choices.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(choices)
        NSLayoutConstraint.activate([choices.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4), choices.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8), choices.topAnchor.constraint(equalTo: document.topAnchor, constant: 4)])
        preview.isSelectable = true; preview.identifier = .init("ai.review.payload")
        preview.font = .oshellMonospacedSystemFont(ofSize: 11, weight: .regular)
        images.spacing = 6; images.alignment = .top; images.orientation = .horizontal
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor
        let right = NSStackView(views: [summary, textScroll, images]); right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
        let row = NSStackView(views: [list, right]); row.orientation = .horizontal; row.spacing = 12; row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor), row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor), list.widthAnchor.constraint(equalToConstant: 260), list.heightAnchor.constraint(equalTo: row.heightAnchor), right.heightAnchor.constraint(equalTo: row.heightAnchor), summary.widthAnchor.constraint(equalTo: right.widthAnchor), textScroll.widthAnchor.constraint(equalTo: right.widthAnchor), textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180), images.widthAnchor.constraint(equalTo: right.widthAnchor)])
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
            preview.string = frozen.preview; preview.enclosingScrollView?.needsLayout = true
            summary.stringValue = "本次发送 \(frozen.items.count) 项 · 历史 \(frozen.items.filter { $0.origin == .history }.count) 项 · 会话字段 \(frozen.items.filter { $0.origin == .identity }.count) 项\n只授权一次；所选文字和图片可能含主机、账号等信息，请逐项检查。图片不会自动遮盖。"
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
        } catch { snapshot = nil; preview.string = error.localizedDescription; summary.stringValue = "尚不能发送；请调整左侧范围。"; approveButton?.isEnabled = false }
        needsLayout = true
    }
    override func layout() {
        super.layout(); preview.enclosingScrollView?.layoutSubtreeIfNeeded(); document.setFrameSize(NSSize(width: list.contentSize.width, height: document.frame.height)); document.layoutSubtreeIfNeeded()
        document.setFrameSize(NSSize(width: list.contentSize.width, height: max(list.contentSize.height, choices.fittingSize.height + 8)))
    }
    static func review(draft: AISendDraft, settings: AISettings, revoke: ((String) -> AISendDraft?)? = nil) -> AIRequest? {
        let alert = PopupAlert(); alert.messageText = "授权本次 AI 发送"
        alert.informativeText = "确认右侧接收接口、模型和内容后再授权。添加附件和查看预览只在本机进行；此授权不允许执行命令。"
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
        let scroll = AIRequestPreview(); scroll.text.string = snapshot.preview; scroll.frame = NSRect(x: 0, y: 0, width: 680, height: 340); alert.accessoryView = scroll
        return alert.runModal() == .alertFirstButtonReturn
    }
}
