// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

final class SessionFullscreenTest {
    private static var retained: SessionFullscreenTest?
    private let workspace: WorkspaceController
    private var checks = [String: Bool](), observations = [NSObjectProtocol]()
    private var entered = false, exited = false, finished = false
    private var manager: SessionManager!
    private var owner: NSWindow { workspace.window! }
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = SessionFullscreenTest(workspace); retained = test
        // Let LaunchServices finish activation before exercising native Spaces.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { test.start() }
    }
    private func wait(_ key: String, until condition: @escaping () -> Bool, then action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(15)
        func poll() {
            guard !finished else { return }
            if condition() { checks[key] = true; action() }
            else if Date() > deadline { checks[key] = false; finish() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
        }
        poll()
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func verifyPopup(_ label: String) {
        guard let popup = manager.window else { checks[label] = false; return }
        checks[label + "OwnedByWorkspace"] = popup.parent === owner && owner.childWindows?.contains(popup) == true
        checks[label + "AuxiliaryInCurrentSpace"] = popup.collectionBehavior.contains(.fullScreenAuxiliary) && popup.collectionBehavior.contains(.moveToActiveSpace) && !popup.collectionBehavior.contains(.canJoinAllSpaces)
        checks[label + "SameActiveSpace"] = popup.isVisible && popup.isOnActiveSpace && owner.isOnActiveSpace
        checks[label + "NormalWindowLevel"] = popup.level == .normal
    }
    private func dismissPopup(_ label: String) {
        let popup = manager.window!
        if let search = descendants(popup.contentView!).first(where: { $0 is NSSearchField }) { popup.makeFirstResponder(search) }
        checks[label + "EscapeClosesOnlyPopup"] = PopupKeyboard.dismiss(window: popup) && !popup.isVisible && owner.isVisible
        checks[label + "DetachedAfterClose"] = popup.parent == nil && !(owner.childWindows?.contains(popup) ?? false)
    }
    private func start() {
        workspace.newBlankTab()
        manager = SessionManager(workspace: workspace)
        owner.collectionBehavior.insert(.fullScreenPrimary)
        owner.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: owner, queue: .main) { [weak self] _ in self?.entered = true })
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: owner, queue: .main) { [weak self] _ in self?.exited = true })
        wait("workspaceActivated", until: { NSApp.isActive && self.owner.isOnActiveSpace }) { [self] in
            manager.show(); verifyPopup("normal"); dismissPopup("normal")
            owner.makeKeyAndOrderFront(nil)
            enterFullscreen()
        }
    }
    private func enterFullscreen() {
        owner.toggleFullScreen(nil)
        wait("enteredNativeFullScreen", until: { self.entered && self.owner.styleMask.contains(.fullScreen) }) { [self] in
            manager.show()
            // Allow any unintended Space transition to complete before asserting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                verifyPopup("fullscreen"); dismissPopup("fullscreen")
                manager.showPreservingMode(); verifyPopup("reopened"); dismissPopup("reopened")
                manager.showFiles { _ in }; verifyPopup("fileSelection")
                manager.window?.orderOut(nil)
                checks["orderOutDetachesChild"] = manager.window?.parent == nil
                manager.show(); verifyPopup("afterHide")
                let alert = PopupAlert(); alert.messageText = "全屏会话管理中的内层弹窗"; alert.addButton(withTitle: "取消")
                let timer = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
                    checks["nestedAlertStaysInFullScreenSpace"] = alert.window.isOnActiveSpace && owner.isOnActiveSpace
                    _ = PopupKeyboard.dismiss(window: alert.window)
                }
                RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
                _ = alert.runModal(); timer.invalidate()
                dismissPopup("beforeExit")
                testOtherPopups()
                owner.toggleFullScreen(nil)
                wait("exitedNativeFullScreen", until: { self.exited && !self.owner.styleMask.contains(.fullScreen) }) { [self] in
                    manager.show(); verifyPopup("restored"); dismissPopup("restored")
                    checks["blankTabPreserved"] = workspace.tabs.count == 1 && workspace.selectedTab?.activePane.isBlank == true
                    finish()
                }
            }
        }
    }
    private func modalTimer(_ action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: 0.8, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }
    private func verifyAuxiliary(_ window: NSWindow, _ label: String, parent: NSWindow) {
        checks[label + "Owner"] = window.parent === parent
        if window.parent !== parent {
            print("Owner mismatch \(label): actual=\(window.parent?.title ?? "nil"), expected=\(parent.title), key=\(NSApp.keyWindow?.title ?? "nil"), main=\(NSApp.mainWindow?.title ?? "nil"), modal=\(NSApp.modalWindow?.title ?? "nil")")
        }
        checks[label + "Space"] = window.isVisible && window.isOnActiveSpace && owner.isOnActiveSpace
        checks[label + "Behavior"] = window.collectionBehavior.contains(.fullScreenAuxiliary) && !window.collectionBehavior.contains(.canJoinAllSpaces)
    }
    private func testOtherPopups() {
        let commands = QuickCommandManager(workspace: workspace)
        let highlights = HighlightManager(workspace: workspace)
        let files = RemoteFileWindow(workspace: workspace)
        for (label, controller) in [("commands", commands as NSWindowController), ("highlights", highlights), ("files", files)] {
            controller.showWindow(nil)
            if label == "files", let fileWindow = controller.window {
                checks["filesIndependentInFullscreen"] = fileWindow.parent == nil && fileWindow.level == .normal
                checks["filesSameFullscreenSpace"] = fileWindow.isVisible && fileWindow.isOnActiveSpace && owner.isOnActiveSpace
                checks["filesAuxiliaryBehavior"] = fileWindow.collectionBehavior.contains(.fullScreenAuxiliary) && !fileWindow.collectionBehavior.contains(.canJoinAllSpaces)
                owner.makeKeyAndOrderFront(nil)
                let ordered = NSApp.orderedWindows
                if let mainIndex = ordered.firstIndex(of:owner), let fileIndex = ordered.firstIndex(of:fileWindow) {
                    checks["fullscreenTerminalCanCoverFiles"] = mainIndex < fileIndex
                } else { checks["fullscreenTerminalCanCoverFiles"] = false }
                checks["filesRemainInFullscreenSpace"] = fileWindow.isOnActiveSpace && owner.isOnActiveSpace
                controller.showWindow(nil)
                checks["filesReopenStillIndependent"] = fileWindow.parent == nil && fileWindow.isOnActiveSpace
            } else { verifyAuxiliary(controller.window!, label, parent: owner) }
            let alert = PopupAlert(); alert.messageText = "嵌套窗口测试"; alert.addButton(withTitle: "取消")
            let timer = modalTimer { [self] in
                verifyAuxiliary(alert.window, label + "Alert", parent: controller.window!)
                _ = PopupKeyboard.dismiss(window: alert.window)
            }
            _ = alert.runModal(); timer.invalidate()
            checks[label + "AlertDetached"] = alert.window.parent == nil
            if label == "files", let fileWindow = controller.window {
                checks["filesEscapeHandled"] = PopupKeyboard.dismiss(window:fileWindow)
                checks["filesEscapeMinimizes"] = fileWindow.isMiniaturized && (controller as? RemoteFileWindow)?.sessions.count == 1
                controller.showWindow(nil)
                // Deminiaturization can finish after showWindow returns. A real
                // Cmd+W is only delivered once the restored window becomes key.
                let restoreDeadline = Date().addingTimeInterval(5)
                while !fileWindow.isKeyWindow && Date() < restoreDeadline {
                    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
                }
                checks["filesRestoredAfterEscape"] = !fileWindow.isMiniaturized && fileWindow.isOnActiveSpace && fileWindow.isKeyWindow
                let close = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:fileWindow.windowNumber,context:nil,characters:"w",charactersIgnoringModifiers:"w",isARepeat:false,keyCode:13)!
                checks["filesCommandWHandled"] = fileWindow.performKeyEquivalent(with:close)
            } else { _ = PopupKeyboard.dismiss(window: controller.window!) }
            checks[label + "Closed"] = !controller.window!.isVisible && controller.window!.parent == nil
        }
        owner.makeKeyAndOrderFront(nil)
        let settingsTimer = modalTimer { [self] in
            guard let settings = NSApp.modalWindow else { checks["settingsPresented"] = false; return }
            verifyAuxiliary(settings, "settings", parent: owner)
            if let well = descendants(settings.contentView!).compactMap({ $0 as? PopupColorWell }).first {
                well.activate(true)
                verifyAuxiliary(NSColorPanel.shared, "colorPicker", parent: settings)
                _ = PopupKeyboard.dismiss(window: NSColorPanel.shared)
                checks["colorPickerDetached"] = NSColorPanel.shared.parent == nil
                well.deactivate()
            } else { checks["settingsColorWell"] = false }
            let panel = NSOpenPanel()
            let timer = modalTimer { [self] in
                verifyAuxiliary(panel, "nestedFilePicker", parent: settings)
                panel.cancel(nil)
            }
            checks["nestedFilePickerCancelled"] = panel.runPopupModal() == .cancel
            timer.invalidate()
            checks["nestedFilePickerDetached"] = panel.parent == nil
            _ = PopupKeyboard.dismiss(window: settings)
        }
        workspace.showAppearancePreferences(); settingsTimer.invalidate()
        checks["settingsDismissed"] = NSApp.modalWindow == nil
        for (label, panel) in [("openPicker", NSOpenPanel() as NSSavePanel), ("savePicker", NSSavePanel())] {
            owner.makeKeyAndOrderFront(nil)
            let timer = modalTimer { [self] in
                verifyAuxiliary(panel, label, parent: owner)
                panel.cancel(nil)
            }
            checks[label + "Cancelled"] = panel.runPopupModal() == .cancel
            timer.invalidate(); checks[label + "Detached"] = panel.parent == nil
        }
        owner.makeKeyAndOrderFront(nil)
        let aboutTimer = modalTimer { [self] in
            if let about = NSApp.modalWindow {
                verifyAuxiliary(about, "about", parent: owner)
                _ = PopupKeyboard.dismiss(window: about)
            } else { checks["aboutPresented"] = false }
        }
        workspace.showAbout(); aboutTimer.invalidate()
    }
    private func finish() {
        guard !finished else { return }; finished = true
        observations.forEach(NotificationCenter.default.removeObserver); observations = []
        manager?.close()
        let output = ProcessInfo.processInfo.environment["OSHELL_FULLSCREEN_OUTPUT"]
        if let output { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output)) }
        print("Fullscreen checks: \(checks.count); failures: \(checks.filter { !$0.value }.keys.sorted())")
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}
