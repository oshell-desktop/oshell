// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum WindowSizeTest {
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exercise(workspace) }
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        let window = workspace.window!, initialFrame = workspace.window!.frame
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let initialPreferences = try? encoder.encode(workspace.configuration.preferences)
        checks["defaultsKeepRememberedSize"] = WindowSizePreferences.customSize == nil
        let control = WindowSizeSettingsControl(currentSize: NSSize(width: 960, height: 600))
        checks["defaultFieldsDisabled"] = control.enabled.state == .off && !control.width.isEnabled && !control.height.isEnabled
        control.enabled.performClick(nil)
        for (w, h) in [("759", "600"), ("960", "459"), ("1.5", "600"), ("abc", "600"), ("10001", "600"), ("960", "10001")] {
            control.width.stringValue = w; control.height.stringValue = h
            do { _ = try control.value(); checks["rejects-\(w)-\(h)"] = false }
            catch { checks["rejects-\(w)-\(h)"] = true }
        }
        control.width.stringValue = "760"; control.height.stringValue = "460"
        checks["minimumAccepted"] = (try? control.value()) == NSSize(width: 760, height: 460)
        control.enabled.performClick(nil)
        checks["disabledIgnoresDraftDimensions"] = (try? control.value()) == nil
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        views(control).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "settings.window.useCurrent" }?.performClick(nil)
        checks["useCurrentEnablesAndFillsDimensions"] = (try? control.value()) == NSSize(width: 960, height: 600) && control.width.isEnabled && control.height.isEnabled

        func edit(apply: Bool, fixed: Bool) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView,
                      let tabs = views(root).compactMap({ $0 as? NSTabView }).first else { checks["settingsOpened"] = false; NSApp.abortModal(); return }
                tabs.selectTabViewItem(withIdentifier: "window"); root.layoutSubtreeIfNeeded()
                guard let page = tabs.selectedTabViewItem?.view,
                      let editor = views(page).compactMap({ $0 as? WindowSizeSettingsControl }).first else { checks["windowSettingsExist"] = false; NSApp.abortModal(); return }
                checks["windowSettingsFitPage"] = page.bounds.contains(editor.convert(editor.bounds, to: page))
                    && views(editor).filter { $0 is NSControl }.allSatisfy { page.bounds.contains($0.convert($0.bounds, to: page)) && $0.bounds.height > 0 }
                if editor.enabled.state != (fixed ? .on : .off) { editor.enabled.performClick(nil) }
                editor.width.stringValue = "960"; editor.height.stringValue = "600"
                views(root).compactMap { $0 as? NSButton }.first { $0.title == (apply ? "应用" : "取消") }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            workspace.showPreferences()
        }
        edit(apply: false, fixed: true)
        checks["cancelDoesNotSave"] = WindowSizePreferences.customSize == nil
        // Establish the existing settings editor's normalized baseline before
        // testing that changing only the local window size leaves it unchanged.
        edit(apply: true, fixed: false)
        let sharedPreferences = try? encoder.encode(workspace.configuration.preferences)
        let before = initialPreferences.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary } ?? [:]
        let after = sharedPreferences.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary } ?? [:]
        let normalizedFields = before.allKeys.compactMap { $0 as? String }.filter { key in
            !NSDictionary(dictionary: [key: before[key] ?? NSNull()]).isEqual(to: [key: after[key] ?? NSNull()])
        }
        edit(apply: true, fixed: true)
        checks["applyPersistsDimensions"] = WindowSizePreferences.customSize == NSSize(width: 960, height: 600)
        checks["applyDoesNotResizeCurrentWindow"] = window.frame == initialFrame
        checks["windowSizeExcludedFromSharedPreferences"] = sharedPreferences != nil && (try? encoder.encode(workspace.configuration.preferences)) == sharedPreferences
        // Exercise the same initializer used at application launch, including frame autosave.
        let startup = WorkspaceController(store: workspace.store, configuration: workspace.configuration)
        checks["startupUsesConfiguredSize"] = startup.window!.contentRect(forFrameRect: startup.window!.frame).size == NSSize(width: 960, height: 600)
        startup.window?.close()
        if let windows = workspace.windowCoordinator {
            let next = windows.newWindow()
            checks["newWindowUsesConfiguredSize"] = next.window!.contentRect(forFrameRect: next.window!.frame).size == NSSize(width: 960, height: 600)
            next.window?.setContentSize(NSSize(width: 1100, height: 700))
            checks["manualResizeKeepsStartupPreference"] = WindowSizePreferences.customSize == NSSize(width: 960, height: 600)
            next.window?.close()
        } else { checks["windowCoordinatorExists"] = false }
        WindowSizePreferences.save(NSSize(width: 10000, height: 10000))
        let oversized = WorkspaceController(store: workspace.store, configuration: workspace.configuration)
        if let probe = oversized.window, let screen = probe.screen {
            checks["oversizedWindowFitsScreen"] = screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(probe.frame)
            checks["screenClampingKeepsRequestedPreference"] = WindowSizePreferences.customSize == NSSize(width: 10000, height: 10000)
        } else { checks["oversizedWindowFitsScreen"] = false }
        oversized.window?.close()
        workspace.show(); workspace.windowCoordinator?.activate(workspace)
        edit(apply: true, fixed: false)
        checks["disablingClearsFixedSize"] = WindowSizePreferences.customSize == nil && UserDefaults.standard.object(forKey: WindowSizePreferences.key) == nil
        checks["disablingDoesNotResizeCurrentWindow"] = window.frame == initialFrame
        UserDefaults.standard.set(["width": -1, "height": 600], forKey: WindowSizePreferences.key)
        checks["invalidSavedSizeFallsBack"] = WindowSizePreferences.customSize == nil
        WindowSizePreferences.save(nil)
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "baselineNormalizedPreferenceFields": normalizedFields]
        if let path = ProcessInfo.processInfo.environment["OSHELL_WINDOW_SIZE_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
