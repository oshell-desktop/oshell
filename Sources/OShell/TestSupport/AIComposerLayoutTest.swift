// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum AIComposerLayoutTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        let editor = AIPromptEditor(frame: .zero, textContainer: nil)
        editor.isRichText = false; editor.font = .systemFont(ofSize: 14); editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 6, height: 8); editor.isVerticallyResizable = true; editor.textContainer?.widthTracksTextView = true
        let input = NSScrollView(); input.documentView = editor; input.drawsBackground = false; input.hasVerticalScroller = true; input.autohidesScrollers = true
        let attachments = NSScrollView(); attachments.drawsBackground = false
        let add = AIComposerAddButton(frame: .zero, pullsDown: true); add.addItem(withTitle: "＋"); add.isBordered = false; add.font = AIComposerTypography.controlFont; add.menu?.font = AIComposerTypography.controlFont; (add.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let approval = NSButton(title: "逐次审批", target: nil, action: nil); approval.isBordered = false; approval.font = AIComposerTypography.controlFont
        approval.image = NSImage(oshellSymbolName: "checkmark.shield", accessibilityDescription: "审批"); approval.image?.size = NSSize(width: 15, height: 15); approval.imagePosition = .imageLeading
        let model = NSPopUpButton(); model.cell = AIComposerPickerCell(textCell: "", pullsDown: false); model.addItems(withTitles: ["合成渠道 · GPT-6 Astra"]); model.isBordered = false; model.font = AIComposerTypography.controlFont; model.cell?.alignment = .right; (model.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let effort = NSPopUpButton(); let cell = AIComposerPickerCell(textCell: "", pullsDown: false); cell.showsEffort = true; effort.cell = cell
        effort.addItems(withTitles: ["跟随模型：中（medium）"]); effort.isBordered = false; effort.font = AIComposerTypography.controlFont
        let send = AIComposerSendButton(title: "发送", target: nil, action: nil), stop = AIComposerSendButton(title: "停止", target: nil, action: nil)
        send.isBordered = false; stop.isBordered = false; stop.showsStop = true; stop.isHidden = true
        let card = AIComposerSurface(input: input, attachments: attachments, add: add, approval: approval, model: model, effort: effort, send: send, stop: stop)
        let root = InterfaceSurfaceView(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 240), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false
        window.contentView = root; root.addSubview(card)
        for width: CGFloat in [300, 340, 420, 640, 900] {
            for height: CGFloat in [0, 60] {
                card.attachmentsHeight = height; card.setFrameSize(NSSize(width: width, height: 200))
                card.frame = NSRect(x: 16, y: 16, width: width, height: card.intrinsicContentSize.height)
                window.setContentSize(NSSize(width: width + 32, height: card.frame.height + 32)); card.needsLayout = true; root.layoutSubtreeIfNeeded()
                let controls = [add, approval, model, effort, send] as [NSView]
                let key = "\(Int(width))-\(Int(height))"
                checks["composerControlsInside-" + key] = controls.allSatisfy { card.bounds.contains($0.frame) }
                checks["composerControlsDoNotOverlap-" + key] = controls.enumerated().allSatisfy { i, first in controls.dropFirst(i + 1).allSatisfy { !first.frame.intersects($0.frame) } }
                checks["composerEditorSeparateFromControls-" + key] = card.bounds.contains(input.frame) && controls.allSatisfy { !input.frame.intersects($0.frame) }
                checks["composerKeepsNativePickers-" + key] = model.titleOfSelectedItem == "合成渠道 · GPT-6 Astra" && effort.titleOfSelectedItem?.contains("medium") == true
                if height == 0, [340, 640].contains(width), let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] {
                    for appearance in [NSAppearance.Name.aqua, .oshellDark] {
                        root.appearance = NSAppearance(named: appearance); let previous = NSAppearance.current; NSAppearance.current = root.effectiveAppearance
                        root.needsDisplay = true; card.needsDisplay = true
                        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                            root.cacheDisplay(in: root.bounds, to: bitmap)
                            let path = URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("ai-composer-\(Int(width))-\(appearance == .aqua ? "light" : "dark").png")
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: path)
                        }
                        NSAppearance.current = previous
                    }
                }
            }
        }
        window.close(); return checks
    }
}
