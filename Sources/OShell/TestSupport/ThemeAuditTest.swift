// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Isolated UI fixtures only; no remote connections or real user credentials.
enum ThemeAuditTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func contrast(_ foreground: NSColor, _ background: NSColor, in view: NSView) -> Double {
            let previous = NSAppearance.current; NSAppearance.current = view.effectiveAppearance
            defer { NSAppearance.current = previous }
            guard let fg = foreground.usingColorSpace(.sRGB), let bg = background.usingColorSpace(.sRGB) else { return 0 }
            func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Double {
                func linear(_ c: CGFloat) -> Double { let v = Double(c); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            }
            let a = fg.alphaComponent
            let l1 = luminance(fg.redComponent * a + bg.redComponent * (1-a), fg.greenComponent * a + bg.greenComponent * (1-a), fg.blueComponent * a + bg.blueComponent * (1-a))
            let l2 = luminance(bg.redComponent, bg.greenComponent, bg.blueComponent)
            return (max(l1,l2) + 0.05) / (min(l1,l2) + 0.05)
        }
        func audit(_ root: NSView, _ name: String, expected: NSAppearance.Name) {
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            let views = descendants(root)
            let controls = views.filter { $0 is NSControl && !$0.isHiddenOrHasHiddenAncestor }
            checks[name + "-controlsInheritTheme"] = !controls.isEmpty && controls.allSatisfy { $0.effectiveAppearance.name == expected }
            for (index, editor) in views.compactMap({ $0 as? NSTextView }).enumerated() where !editor.isFieldEditor {
                checks[name + "-editor\(index)TextContrast"] = contrast(editor.textColor ?? .textColor, editor.backgroundColor, in: editor) >= 3
                checks[name + "-editor\(index)CaretContrast"] = contrast(editor.insertionPointColor, editor.backgroundColor, in: editor) >= 3
                if !editor.string.isEmpty, let color = editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
                    checks[name + "-editor\(index)ExistingTextContrast"] = contrast(color, editor.backgroundColor, in: editor) >= 3
                }
            }
        }
        func modal(_ name: String, body: () -> Void) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                guard let window = NSApp.modalWindow, let root = window.contentView else { checks[name + "-opened"] = false; NSApp.abortModal(); return }
                for (index, theme) in [InterfaceTheme.dark, .light, .dark, .light].enumerated() {
                    ApplicationAppearance.apply(theme)
                    let expected: NSAppearance.Name = theme == .dark ? .darkAqua : .aqua
                    if let tabs = descendants(root).compactMap({ $0 as? NSTabView }).first {
                        for page in tabs.tabViewItems.indices {
                            tabs.selectTabViewItem(at: page)
                            audit(root, name + "-\(index)-page\(page)", expected: expected)
                        }
                    } else { audit(root, name + "-\(index)", expected: expected) }
                }
                _ = PopupKeyboard.dismiss(window: window)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            body()
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try! encoder.encode(workspace.configuration)
        ApplicationAppearance.apply(.dark)
        modal("paste-preview") { _ = InputDialogs.previewPaste("echo 'literal'\nprintf test", destinations: "Theme test") }
        modal("session-editor") { _ = SessionEditor(nil, profiles: [], directories: ["/"], initialDirectory: "/").run() }
        modal("session-defaults") { _ = SessionDefaultsEditor(workspace.configuration.sessionDefaults).run() }
        modal("live-properties") { _ = LiveSessionProperties(profile: SessionProfile(), title: "Theme test", defaults: KeepAliveSettings(), canPersist: false).run() }
        modal("proxy-manager") { ProxyManager(workspace: workspace).run() }
        modal("proxy-editor") { _ = ProxyEditor(nil, workspace: workspace).run() }
        modal("session-picker") { _ = QuickSessionPicker(entries: []).run() }
        modal("target-picker") { _ = InputDialogs.targets([], selected: [], title: "目标会话") }
        modal("directory-picker") { _ = SessionDirectoryTree.choose(directories: ["/dev", "/ops"], selected: "/dev") }
        modal("confirmation") { _ = Dialogs.confirm("主题测试", text: "取消即可关闭。", action: "确定") }
        modal("settings-pages") { workspace.showPreferences() }

        let sessionManager = SessionManager(workspace: workspace)
        let commands = QuickCommandManager(workspace: workspace)
        let highlights = HighlightManager(workspace: workspace)
        let files = RemoteFileWindow(workspace: workspace)
        let fileSession = RemoteFileSession(workspace: workspace)
        let utility = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        utility.isReleasedWhenClosed = false
        for (name, controller) in [("session-list", sessionManager as NSWindowController), ("quick-commands", commands), ("highlights", highlights), ("file-window", files)] {
            guard let window = controller.window, let root = window.contentView else { continue }
            for (index, theme) in [InterfaceTheme.dark, .light, .dark, .light].enumerated() {
                ApplicationAppearance.apply(theme); window.makeKeyAndOrderFront(nil)
                audit(root, "\(name)-\(index)", expected: theme == .dark ? .darkAqua : .aqua)
            }
            window.orderOut(nil)
        }
        for (name, view) in [("file-browser", fileSession.view), ("composer", CommandComposer()), ("conflicts", SharedConflictView([]))] {
            utility.contentView = view; utility.makeKeyAndOrderFront(nil)
            for (index, theme) in [InterfaceTheme.dark, .light, .dark, .light].enumerated() {
                ApplicationAppearance.apply(theme)
                audit(view, "\(name)-\(index)", expected: theme == .dark ? .darkAqua : .aqua)
            }
        }
        utility.orderOut(nil)
        // A child of a settings-preview window must follow that window, not
        // the application's still-uncommitted saved appearance.
        let child = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        for theme in [InterfaceTheme.dark, .light] {
            ApplicationAppearance.apply(theme == .dark ? .light : .dark)
            utility.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            PopupPresentation.prepare(child, over: utility)
            checks["nested-\(theme.rawValue)-inheritsPreview"] = child.effectiveAppearance.name == utility.effectiveAppearance.name
            let flipped = NSAppearance(named: theme == .dark ? .aqua : .darkAqua)
            PopupPresentation.applyAppearance(flipped, to: utility)
            checks["nested-\(theme.rawValue)-updatesWhileOpen"] = child.effectiveAppearance.name == utility.effectiveAppearance.name
            PopupPresentation.detach(child)
            let panel = NSColorPanel.shared
            PopupPresentation.prepare(panel, over: utility)
            checks["color-panel-\(theme.rawValue)-inheritsPreview"] = panel.effectiveAppearance.name == utility.effectiveAppearance.name
            PopupPresentation.applyAppearance(NSAppearance(named: theme == .dark ? .darkAqua : .aqua), to: utility)
            checks["color-panel-\(theme.rawValue)-updatesWhileOpen"] = panel.effectiveAppearance.name == utility.effectiveAppearance.name
            let panelLabels = descendants(panel.contentView!).compactMap { $0 as? NSTextField }
            checks["color-panel-\(theme.rawValue)-labelsFollowWindow"] = panelLabels.allSatisfy { $0.effectiveAppearance.name == panel.effectiveAppearance.name }
            PopupPresentation.detach(panel)
        }
        child.close()
        let chips = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 140)); utility.contentView = chips
        for (index, hex) in ["#FFFFFF", "#000000", "#FFFF00"].enumerated() {
            let cell = HighlightColorCell(hex: hex); cell.frame = NSRect(x: 10, y: CGFloat(index * 30), width: 180, height: 28); chips.addSubview(cell)
            for theme in [InterfaceTheme.dark, .light] {
                PopupPresentation.applyAppearance(NSAppearance(named: theme == .dark ? .darkAqua : .aqua), to: utility)
                checks["highlight-\(hex)-\(theme.rawValue)-readableCode"] = contrast(cell.textField!.textColor!, .windowBackgroundColor, in: cell) >= 3
                checks["highlight-\(hex)-\(theme.rawValue)-preservesValue"] = cell.textField?.stringValue == hex
            }
        }
        utility.close(); fileSession.shutdown(); files.close()
        workspace.newBlankTab()
        if let pane = workspace.selectedTab?.activePane {
            let schemes = [TerminalColorScheme.presets.first { $0.isDark }!, TerminalColorScheme.presets.first { !$0.isDark }!]
            for scheme in schemes {
                var prefs = workspace.configuration.preferences; prefs.colorSchemeID = scheme.id; prefs.terminalClockEnabled = true
                pane.apply(prefs); pane.searchPanel.show(prefillSelection: false, performSearch: false)
                pane.transferProgress.begin("Theme test")
                for theme in [InterfaceTheme.dark, .light] {
                    ApplicationAppearance.apply(theme)
                    let expected: NSAppearance.Name = scheme.isDark ? .darkAqua : .aqua
                    let prefix = "pane-\(scheme.id)-\(theme.rawValue)"
                    checks[prefix + "-searchAndProgressFollowTerminal"] = pane.searchPanel.effectiveAppearance.name == expected && pane.transferProgress.effectiveAppearance.name == expected
                    checks[prefix + "-paletteUnaffected"] = pane.terminal.nativeBackgroundColor.rgbHex == scheme.background && pane.terminal.nativeForegroundColor.rgbHex == scheme.foreground
                    checks[prefix + "-searchReadable"] = contrast(pane.searchPanel.status.textColor!, pane.terminal.nativeBackgroundColor, in: pane.searchPanel) >= 2
                    checks[prefix + "-progressReadable"] = contrast(pane.transferProgress.details.textColor!, .windowBackgroundColor, in: pane.transferProgress) >= 2
                }
            }
            pane.transferProgress.hide(); pane.searchPanel.hide()
        }

        checks["auditDidNotSaveConfiguration"] = (try? encoder.encode(workspace.configuration)) == original
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_THEME_AUDIT_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
