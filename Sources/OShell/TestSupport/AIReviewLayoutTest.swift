// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum AIReviewLayoutTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        do {
            var settings = AISettings(); settings.endpoint = "https://layout.example.test/v1"; settings.model = "synthetic-model"; settings.supportsImages = true
            var items = [AIDisclosure(id: "question", name: "本次问题", text: String(repeating: "合成资料：长文本用于验证完整预览。\n", count: 250) + "END_OF_PREVIEW")]
            let png = try ImagePasteTest.sample().png
            for index in 0..<4 { items.append(.init(id: "image-\(index)", name: "合成图片 \(index)", text: "合成图片", image: .init(name: "synthetic-\(index).png", png: png))) }
            for index in 0..<30 { items.append(.init(id: "identity-\(index)", name: "会话信息 · 合成字段 \(index)", text: "fixture", origin: .identity)) }
            let draft = AISendDraft(scope: UUID(), revision: UUID(), items: items, requiredID: "question")
            for width: CGFloat in [520, 760, 980] {
                for height: CGFloat in [300, 520] {
                    let review = AISendReview(draft: draft, settings: settings, approveButton: NSButton())
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = review; review.frame.size = NSSize(width: width, height: height)
                    review.layoutSubtreeIfNeeded()
                    let key = "reviewLayout:\(Int(width))x\(Int(height))"
                    let scrolls = views(review).compactMap { $0 as? NSScrollView }
                    let source = scrolls.first { $0.identifier?.rawValue == "ai.review.sources" }!
                    let preview = scrolls.first { $0.identifier?.rawValue == "ai.review.previewScroll" }!
                    let images = scrolls.first { $0.identifier?.rawValue == "ai.review.images" }!
                    let first = views(review).first { $0.identifier?.rawValue == "ai.review.item.question" }!
                    checks[key + ":firstChoiceVisible"] = source.documentVisibleRect.contains(first.convert(first.bounds, to: source.documentView))
                    checks[key + ":allRegionsFit"] = [source, preview, images].allSatisfy { review.bounds.contains($0.frame) }
                    checks[key + ":previewStartsAtTop"] = preview.documentVisibleRect.minY < 1
                    let controls = views(source.documentView!).compactMap { $0 as? NSControl }
                    checks[key + ":noHorizontalClipping"] = controls.allSatisfy { let rect = $0.convert($0.bounds, to: source.documentView); return rect.minX >= 0 && rect.maxX <= source.contentSize.width + 1 && rect.width > 150 }
                    let last = views(review).first { $0.identifier?.rawValue == "ai.review.item.identity-29" }!
                    source.contentView.scroll(to: NSPoint(x: 0, y: source.documentView!.bounds.height - source.contentSize.height))
                    checks[key + ":lastChoiceReachable"] = source.documentVisibleRect.contains(last.convert(last.bounds, to: source.documentView))
                    preview.contentView.scroll(to: NSPoint(x: 0, y: preview.documentView!.bounds.height - preview.contentSize.height))
                    let text = preview.documentView as! NSTextView
                    let bottom = text.layoutManager!.usedRect(for: text.textContainer!).maxY + text.textContainerInset.height
                    checks[key + ":lastLineReachable"] = text.visibleRect.maxY >= bottom && text.string.contains("END_OF_PREVIEW")
                    checks[key + ":imagesHaveScrollSpace"] = images.documentView!.bounds.width >= 392
                    window.close()
                }
            }
        } catch { checks["reviewLayoutSetup"] = false; print("Review layout fixture:", error.localizedDescription) }
        return checks
    }
}
