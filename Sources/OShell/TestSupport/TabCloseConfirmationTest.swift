// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum TabCloseConfirmationTest {
    static func run(_ workspace: WorkspaceController) {
        RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in exercise(workspace) }, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func views(_ view: NSView) -> [NSView] { [view] + ((view as? NSTabView)?.tabViewItems.compactMap(\.view) ?? view.subviews).flatMap(views) }
        func checkbox(_ view: NSView) -> NSButton? { views(view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "tabs.confirmClose" } }
        func prompt(_ action: () -> Void, answer: String = "取消") -> Bool {
            var appeared = false
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                guard let root = NSApp.modalWindow?.contentView else { return }
                appeared = true
                views(root).compactMap { $0 as? NSButton }.first { $0.title == answer }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            action(); timer.invalidate(); return appeared
        }
        func setEnabled(_ enabled: Bool) throws {
            let view = SessionTitleSettingsView()
            guard let toggle = checkbox(view) else { throw ModelError.invalid("Missing confirmation option") }
            toggle.state = enabled ? .on : .off
            try view.apply(profiles: workspace.configuration.profiles)
        }
        do {
            let legacy = Data(#"{"version":1,"defaultMode":"sessionName","overrides":{}}"#.utf8)
            checks["legacyDefaultsToConfirmation"] = try JSONDecoder().decode(SessionTitleSettings.self, from: legacy).confirmTabClose
            checks["defaultEnabled"] = SessionTitleSettings.shouldConfirmTabClose
            let draft = SessionTitleSettingsView(); checkbox(draft)?.state = .off
            checks["unappliedDraftHasNoEffect"] = SessionTitleSettings.shouldConfirmTabClose
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let before = try encoder.encode(workspace.configuration)
            workspace.newLocal()
            guard let first = workspace.selectedTab else { throw ModelError.invalid("Missing local tab") }
            checks["activeFixture"] = first.activePane.hasActiveProcess
            checks["shortcutPathPrompts"] = prompt { workspace.closeTab() }
            checks["cancelPreservesTab"] = workspace.tabs.contains { $0 === first } && !first.activePane.isShutdown
            try setEnabled(false)
            checks["savedDisabled"] = try !SessionTitleSettings.load().confirmTabClose
            guard let root = workspace.window?.contentView, let strip = views(root).compactMap({ $0 as? TabStripView }).first else { throw ModelError.invalid("Missing tab strip") }
            checks["closeButtonSkipsPrompt"] = !prompt { strip.onClose?(first.id) }
            checks["closeButtonEndsTab"] = !workspace.tabs.contains { $0 === first } && first.activePane.isShutdown
            workspace.newLocal(); let menu = NSMenuItem(); menu.representedObject = workspace.selectedTab?.id
            checks["menuSkipsPrompt"] = !prompt { workspace.closeTabFromMenu(menu) } && workspace.tabs.isEmpty
            workspace.newLocal()
            checks["shortcutSkipsPrompt"] = !prompt { workspace.closeTab() } && workspace.tabs.isEmpty
            workspace.newLocal(); workspace.splitVertical()
            guard let split = workspace.selectedTab, split.layout.panes.count == 2 else { throw ModelError.invalid("Missing split fixture") }
            let closing = split.activePane
            checks["splitSkipsPrompt"] = !prompt { workspace.closeSessionPane(closing) }
            checks["splitKeepsOtherPane"] = closing.isShutdown && split.layout.panes.count == 1 && !split.activePane.isShutdown
            let other = workspace.windowCoordinator?.newWindow(); other?.newLocal()
            checks["otherWindowUsesGlobalOption"] = !prompt { other?.closeTab() } && other?.tabs.isEmpty == true
            try setEnabled(true)
            checks["reenabledPrompts"] = prompt({ workspace.closeTab() }, answer: "关闭")
            checks["confirmClosesTab"] = workspace.tabs.isEmpty
            workspace.newBlankTab()
            checks["blankNeedsNoConfirmation"] = !prompt { workspace.closeTab() } && workspace.tabs.isEmpty
            checks["sharedConfigurationUnchanged"] = try encoder.encode(workspace.configuration) == before
            let close = Timer(timeInterval: 0.15, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView,
                      let tabs = views(root).compactMap({ $0 as? NSTabView }).first else { checks["settingsOptionVisible"] = false; NSApp.abortModal(); return }
                tabs.selectTabViewItem(withIdentifier: "titles"); root.layoutSubtreeIfNeeded()
                if let toggle = checkbox(root), let parent = toggle.superview {
                    checks["settingsOptionVisible"] = !toggle.isHiddenOrHasHiddenAncestor && root.bounds.contains(parent.convert(toggle.frame, to: root))
                } else { checks["settingsOptionVisible"] = false }
                _ = PopupKeyboard.dismiss(window: NSApp.modalWindow!)
            }
            RunLoop.main.add(close, forMode: .common); RunLoop.main.add(close, forMode: .modalPanel)
            workspace.showPreferences()
        } catch { checks["unexpectedError"] = false; print("Tab close fixture:", error.localizedDescription) }
        if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_CLOSE_CONFIRMATION_OUTPUT"] { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        workspace.windowCoordinator?.workspaces.forEach { $0.shutdown() }; NSApp.terminate(nil)
    }
}
