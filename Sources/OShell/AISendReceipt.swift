// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// No credentials or image pixels: immutable descriptions of the submitted body.
struct AISendReceipt: Codable, Equatable {
    let id: UUID
    let date: Date
    let endpoint: String, model: String, channel: String, digest: String, content: String
    var outcome: String
    init(_ request: AIRequest) {
        id = request.id; date = Date(); endpoint = request.endpoint; model = request.model; channel = request.channelName; digest = request.bodyDigest
        let rules = request.taskInstruction.map { "客户端系统任务规则（非用户附件）：\n" + $0 + "\n\n" } ?? ""
        let context = request.contextNote.map { $0 + "\n\n" } ?? ""
        let contents = request.items.enumerated().map { index, item in
            let origin = item.origin == .identity ? "会话信息" : item.origin == .history ? "历史资料" : "本次资料"
            var value = "\(index + 1). \(item.name)（\(origin)，\(item.role == "assistant" ? "AI 回复" : "用户资料")）\n\(item.text)"
            if let image = item.image { value += "\n图片：\(image.name) · \(image.png.count) 字节\nSHA256：\(AIRequest.digest(image.png))\n已提交原图，审阅记录不保存图片像素。" }
            return value
        }.joined(separator: "\n\n")
        content = rules + context + contents
        outcome = "已提交，等待响应"
    }
    var readable: String {
        "发送给：\(channel) · \(model)\n状态：\(outcome)\n\n" + content + "\n\n—— 发送信息 ——\n时间：\(date.description(with: .current))\n服务地址：\(endpoint)\n请求 SHA256：\(digest)\n另附 OShell 助手规则；未选择的会话信息和其他历史没有发送。记录表示客户端已提交，不保证服务端成功接收或处理。"
    }
}

final class AISendReceiptView: InterfaceSurfaceView {
    override var isFlipped: Bool { true }
    private var receipts: [AISendReceipt]
    private let picker = NSPopUpButton(), hint = NSTextField(wrappingLabelWithString: "当前对话最近的发送记录（最多 20 次 / 约 4 MiB）。这里只查看，不发送任何请求。")
    private let scroll = NSScrollView(), text = NSTextView()
    init(receipts: [AISendReceipt]) {
        self.receipts = Array(receipts.reversed())
        super.init(frame: NSRect(x: 0, y: 0, width: 740, height: 440))
        identifier = .init("ai.receipts")
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
        for (index, receipt) in self.receipts.enumerated() {
            picker.addItem(withTitle: "\(self.receipts.count - index) · \(formatter.string(from: receipt.date)) · \(receipt.model) · \(receipt.outcome)")
        }
        picker.cell?.lineBreakMode = .byTruncatingMiddle
        picker.identifier = .init("ai.receipts.choice"); picker.target = self; picker.action = #selector(changed)
        picker.isEnabled = !receipts.isEmpty
        text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 13)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 10, height: 10); text.identifier = .init("ai.receipts.content")
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        for view in [picker, hint, scroll] { addSubview(view) }
        changed()
    }
    func update(_ values: [AISendReceipt]) {
        let next = Array(values.reversed()); guard next != receipts else { return }
        let selected = receipts.indices.contains(picker.indexOfSelectedItem) ? receipts[picker.indexOfSelectedItem].id : nil
        receipts = next; picker.removeAllItems()
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
        for (index, receipt) in receipts.enumerated() { picker.addItem(withTitle: "\(receipts.count - index) · \(formatter.string(from: receipt.date)) · \(receipt.model) · \(receipt.outcome)") }
        if let selected, let index = receipts.firstIndex(where: { $0.id == selected }) { picker.selectItem(at: index) }
        picker.isEnabled = !receipts.isEmpty; changed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() {
        text.string = receipts.indices.contains(picker.indexOfSelectedItem) ? receipts[picker.indexOfSelectedItem].readable : "暂无逐次发送记录。旧版历史没有保存此信息，不能据本机消息推断曾发送过哪些资料。"
        needsLayout = true; layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: .zero)
    }
    override func layout() {
        super.layout(); picker.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 28)
        hint.isHidden = bounds.height < 160
        hint.frame = NSRect(x: 0, y: 34, width: bounds.width, height: 34)
        let top: CGFloat = hint.isHidden ? 34 : 74
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(1, bounds.height - top))
        text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(1, text.frame.height)))
        if let container = text.textContainer, let manager = text.layoutManager {
            container.containerSize = NSSize(width: max(1, scroll.contentSize.width - 20), height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, manager.usedRect(for: container).height + 20)))
        }
    }
}
