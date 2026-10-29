// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import SwiftTerm
import OShellCore

enum AppearanceFeatureTest {
    private final class ProbeTerminal: TerminalView {
        var responses = Data()
        override func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) { responses.append(contentsOf: data) }
    }
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func modal(_ body: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.08, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { body(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
        }
        let catalog = TerminalFontCatalog.available()
        checks["systemFontCatalogExpanded"] = catalog.filter(\.system).count > 8
        checks["fontCatalogHasNoDuplicateFaces"] = Set(catalog.map(\.name)).count == catalog.count
        checks["catalogFontsAreLocallyAvailable"] = catalog.allSatisfy { NSFont(name: $0.name, size: 13) != nil }
        checks["catalogContainsMonospacedAndProportional"] = catalog.contains { $0.system && $0.monospaced } && catalog.contains { $0.system && !$0.monospaced }
        let missingPicker = NSPopUpButton()
        TerminalFontCatalog.populate(missingPicker, selected: "OShell-Missing-Font-Fixture")
        checks["missingFontSelectionPreserved"] = missingPicker.selectedItem?.representedObject as? String == "OShell-Missing-Font-Fixture"
        checks["missingFontUsesSystemPreview"] = TerminalFontCatalog.previewFont(missingPicker).fontName == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
        checks["fontSectionHeadersDisabled"] = missingPicker.itemArray.filter { $0.representedObject == nil }.allSatisfy { !$0.isEnabled || $0.isSeparatorItem }
        let additionalSystemFont = catalog.first { $0.system && $0.monospaced && !["Menlo-Regular", "Monaco", "SFMono-Regular", "CourierNewPSMT"].contains($0.name) }
        checks["additionalSystemMonospaceAvailable"] = additionalSystemFont != nil
        let terminal = ProbeTerminal(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        terminal.feed(text: "HISTORY_PRESERVED 中文\r\n\u{1b}[31mRED\u{1b}[0m \u{1b}[38;2;1;2;3mTRUECOLOR\u{1b}[0m\r\n")
        let original = terminal.getTerminal().getBufferAsData()
        for scheme in TerminalColorScheme.presets {
            scheme.apply(to: terminal)
            checks[scheme.id + "-background"] = terminal.nativeBackgroundColor.rgbHex == scheme.background
            checks[scheme.id + "-foreground"] = terminal.nativeForegroundColor.rgbHex == scheme.foreground
            checks[scheme.id + "-cursor-selection"] = terminal.caretColor.rgbHex == scheme.cursor && terminal.selectedTextBackgroundColor.rgbHex == scheme.selection && terminal.selectedTextForegroundColor.rgbHex == scheme.selectionText
            for index in 0..<16 {
                terminal.responses = Data(); terminal.feed(text: "\u{1b}]4;\(index);?\u{7}")
                let value = UInt32(scheme.ansi[index].dropFirst(), radix: 16)!
                let expected = String(format: "rgb:%04x/%04x/%04x", (value >> 16 & 255) * 257, (value >> 8 & 255) * 257, (value & 255) * 257)
                checks[scheme.id + "-ansi-\(index)"] = String(decoding: terminal.responses, as: UTF8.self).lowercased().contains(expected)
            }
            checks[scheme.id + "-history"] = terminal.getTerminal().getBufferAsData() == original
        }
        let draft = AppearanceSettingsView(preferences: controller.configuration.preferences)
        checks["controlsInsidePanel"] = descendants(draft).filter { $0 is NSColorWell || $0 === draft.theme || $0 === draft.schemes || $0 === draft.name || $0 === draft.copyButton || $0 === draft.deleteButton }.allSatisfy { draft.bounds.contains($0.convert($0.bounds, to: draft)) }
        checks["allColorControlsPresent"] = draft.wells.count == 22
        draft.wells[0].color = NSColor(hex: "#123456")!; draft.colorChanged(draft.wells[0]); draft.name.stringValue = "自定义测试"
        let changed = try! draft.values(updating: controller.configuration.preferences)
        checks["editingPresetCreatesCopy"] = changed.colorScheme.id.hasPrefix("custom-") && changed.colorScheme.background == "#123456" && TerminalColorScheme.presets[0].background == "#11151A"
        checks["draftDoesNotMutateConfiguration"] = controller.configuration.preferences.customColorSchemes.isEmpty
        checks["customNameSaved"] = changed.colorScheme.name == "自定义测试"
        draft.deleteScheme(); checks["deleteOnlyCustom"] = draft.custom.isEmpty && draft.selectedID == "oshell-dark" && !draft.deleteButton.isEnabled
        draft.dispose()
        controller.configuration.preferences.metal = false
        controller.newLocal(); controller.newLocal()
        let panes = controller.tabs.flatMap { $0.layout.panes }, pids = panes.map { $0.terminal.process.shellPid }
        let previousRevision = controller.configurationRevision
        let savedAppTheme = ApplicationAppearance.theme
        let savedWorkspaceAppearance = controller.window?.effectiveAppearance.name
        modal { root in
            let view = descendants(root).compactMap { $0 as? AppearanceSettingsView }.first!
            let palette = view.preview.nativeBackgroundColor
            let systemAppearance: NSAppearance.Name
            systemAppearance = NSApp.effectiveAppearance.name
            for (index, theme) in [InterfaceTheme.dark, .light, .dark, .light, .system].enumerated() {
                view.theme.selectItem(at: InterfaceTheme.allCases.firstIndex(of: theme)!)
                view.themeChanged()
                let expected = theme == .dark ? NSAppearance.Name.darkAqua : (theme == .light ? .aqua : systemAppearance)
                checks["previewTheme\(index)WholeWindow"] = root.window?.effectiveAppearance.name == expected && view.effectiveAppearance.name == expected
                checks["previewTheme\(index)ControlsInheritWindow"] = descendants(root).filter { $0 is NSControl || $0 is NSTabView }.allSatisfy { $0.effectiveAppearance.name == expected }
                checks["previewTheme\(index)NoPageOverride"] = view.appearance == nil
                checks["previewTheme\(index)PaletteIndependent"] = view.preview.nativeBackgroundColor == palette
                checks["previewTheme\(index)MainWindowUnchanged"] = ApplicationAppearance.theme == savedAppTheme && controller.window?.effectiveAppearance.name == savedWorkspaceAppearance
            }
            view.schemes.selectItem(at: 2); view.schemeChanged()
            view.theme.selectItem(at: 2); view.themeChanged()
            checks["modalPreviewDoesNotApplyEarly"] = ApplicationAppearance.theme != .dark
            if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
        }
        controller.showAppearancePreferences()
        checks["cancelDoesNotSave"] = controller.configurationRevision == previousRevision
        checks["cancelPreservesApplicationTheme"] = ApplicationAppearance.theme == savedAppTheme && controller.window?.effectiveAppearance.name == savedWorkspaceAppearance
        modal { root in
            let view = descendants(root).compactMap { $0 as? AppearanceSettingsView }.first!
            let settingsTabs = descendants(root).compactMap { $0 as? NSTabView }.first
            settingsTabs?.selectTabViewItem(at: 0)
            let fonts = descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.itemArray.contains { ($0.representedObject as? String) == "DejaVuSansMono" } }
            checks["dejavuInFontPicker"] = fonts != nil
            if let fonts, let item = fonts.itemArray.first(where: { ($0.representedObject as? String) == "DejaVuSansMono" }) { fonts.select(item) }
            settingsTabs?.selectTabViewItem(at: 1)
            view.schemes.selectItem(at: 6); view.schemeChanged()
            view.theme.selectItem(at: 2); view.themeChanged()
            func submit() { descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil) }
            if let path = ProcessInfo.processInfo.environment["OSHELL_APPEARANCE_PREVIEW"], let window = NSApp.modalWindow {
                root.layoutSubtreeIfNeeded(); window.display()
                let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                    let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
                    try? capture.run(); capture.waitUntilExit(); submit()
                }
                RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
            } else { submit() }
        }
        controller.showAppearancePreferences()
        checks["settingsSavePaletteAndTheme"] = controller.configuration.preferences.colorSchemeID == "nord" && controller.configuration.preferences.interfaceTheme == .dark
        checks["dejavuSavedAcrossReload"] = (try? controller.store.load().preferences.fontName) == "DejaVuSansMono"
        checks["dejavuAppliesAllOpenTerminals"] = panes.allSatisfy { $0.terminal.font.fontName == "DejaVuSansMono" }
        modal { root in
            let tabs = descendants(root).compactMap { $0 as? NSTabView }.first
            tabs?.selectTabViewItem(at: 0)
            let fonts = descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "settings.terminal.font" }
            let item = fonts?.itemArray.first { ($0.representedObject as? String) == "CascadiaCode-Regular" }
            checks["cascadiaInSettings"] = item != nil
            if let fonts, let item { fonts.select(item) }
            descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
        }
        controller.showPreferences()
        checks["cascadiaSavedAcrossReload"] = (try? controller.store.load().preferences.fontName) == "CascadiaCode-Regular"
        checks["cascadiaAppliesAllOpenTerminals"] = panes.allSatisfy { $0.terminal.font.fontName == "CascadiaCode-Regular" }
        modal { root in
            let tabs = descendants(root).compactMap { $0 as? NSTabView }.first
            tabs?.selectTabViewItem(at: 0)
            let fonts = descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "settings.terminal.font" }
            let item = fonts?.itemArray.first { ($0.representedObject as? String) == "CascadiaCode-Light" }
            checks["cascadiaLightInSettings"] = item != nil
            if let fonts, let item { fonts.select(item) }
            descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
        }
        controller.showPreferences()
        checks["cascadiaLightSavedAcrossReload"] = (try? controller.store.load().preferences.fontName) == "CascadiaCode-Light"
        checks["cascadiaLightAppliesAllOpenTerminals"] = panes.allSatisfy { $0.terminal.font.fontName == "CascadiaCode-Light" }
        checks["savedAcrossReload"] = (try? controller.store.load().preferences.colorSchemeID) == "nord"
        checks["appliesAllOpenTerminals"] = panes.allSatisfy { $0.terminal.nativeBackgroundColor.rgbHex == "#2E3440" }
        checks["doesNotRecreateConnections"] = panes.map { $0.terminal.process.shellPid } == pids
        checks["appThemeApplied"] = ApplicationAppearance.theme == .dark && controller.window?.appearance?.name == .darkAqua
        modal { root in
            let view = descendants(root).compactMap { $0 as? AppearanceSettingsView }.first!
            view.theme.selectItem(at: InterfaceTheme.allCases.firstIndex(of: .system)!); view.themeChanged()
            let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            checks["systemPreviewIgnoresSavedDarkOverride"] = root.window?.effectiveAppearance.name == (dark ? .darkAqua : .aqua)
            checks["systemPreviewDoesNotApplyEarly"] = ApplicationAppearance.theme == .dark && controller.window?.appearance?.name == .darkAqua
            if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
        }
        controller.showAppearancePreferences()
        checks["cancelSystemPreviewKeepsDarkSetting"] = controller.configuration.preferences.interfaceTheme == .dark

        if let additionalSystemFont {
            modal { root in
                let tabs = descendants(root).compactMap { $0 as? NSTabView }.first
                tabs?.selectTabViewItem(at: 0)
                let picker = descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "settings.terminal.font" }
                if let picker, let item = picker.itemArray.first(where: { ($0.representedObject as? String) == additionalSystemFont.name }) {
                    picker.select(item); picker.sendAction(picker.action!, to: picker.target)
                    if let page = descendants(root).first(where: { $0 is GeneralSettingsView }) {
                        root.layoutSubtreeIfNeeded()
                        checks["expandedFontControlsFitPage"] = descendants(page).filter { $0 is NSButton || $0 is NSTextField }.allSatisfy { page.bounds.contains($0.convert($0.bounds, to: page)) }
                    }
                } else { checks["additionalFontInPicker"] = false }
                descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
            }
            controller.showPreferences()
            checks["systemFontSavedAndApplied"] = (try? controller.store.load().preferences.fontName) == additionalSystemFont.name && panes.allSatisfy { $0.terminal.font.fontName == additionalSystemFont.name }
            checks["systemFontKeepsConnections"] = panes.map { $0.terminal.process.shellPid } == pids
            checks["systemFontKeepsSymbolFallback"] = panes.allSatisfy { $0.terminal.privateUseFallbackFont != nil }
        }
        modal { root in
            guard let history = descendants(root).compactMap({ $0 as? ScrollbackSettingsControl }).first else { checks["customHistoryControl"] = false; NSApp.abortModal(); return }
            history.picker.selectItem(withTitle: "自定义…"); history.custom.stringValue = "45000"; history.selectionChanged()
            checks["customHistoryVisible"] = !history.custom.isHidden
            checks["largeHistoryRiskVisible"] = history.warning.stringValue.contains("内存不足") && history.warning.textColor == .systemOrange
            root.layoutSubtreeIfNeeded()
            if let page = descendants(root).first(where: { $0 is GeneralSettingsView }) {
                checks["customHistoryControlsFit"] = descendants(page).filter { ($0 is NSButton || $0 is NSTextField) && !$0.isHidden }.allSatisfy { page.bounds.contains($0.convert($0.bounds, to: page)) }
            }
            descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
        }
        controller.showPreferences()
        checks["customHistorySaved"] = controller.configuration.preferences.scrollback == 45000 && (try? controller.store.load().preferences.scrollback) == 45000
        checks["customHistoryAppliesWithoutReconnect"] = panes.allSatisfy { $0.terminal.getTerminal().options.scrollback == 45000 } && panes.map { $0.terminal.process.shellPid } == pids
        modal { root in
            guard let history = descendants(root).compactMap({ $0 as? ScrollbackSettingsControl }).first else { checks["customHistoryRestored"] = false; NSApp.abortModal(); return }
            checks["customHistoryRestored"] = history.picker.titleOfSelectedItem == "自定义…" && history.custom.stringValue == "45000"
            history.custom.stringValue = "100001"; history.selectionChanged()
            modal { errorRoot in
                checks["invalidHistoryBlocked"] = descendants(errorRoot).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("500～100000") }
                if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
                modal { _ in if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
            }
            descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
        }
        controller.showPreferences()
        checks["invalidAndCancelledHistoryNotSaved"] = controller.configuration.preferences.scrollback == 45000 && (try? controller.store.load().preferences.scrollback) == 45000
        modal { root in
            guard let history = descendants(root).compactMap({ $0 as? ScrollbackSettingsControl }).first else { checks["presetHistoryControl"] = false; NSApp.abortModal(); return }
            history.picker.selectItem(withTitle: "3000"); history.selectionChanged()
            checks["presetHidesCustomInput"] = history.custom.isHidden
            descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
        }
        controller.showPreferences()
        checks["presetHistoryStillWorks"] = controller.configuration.preferences.scrollback == 3000 && panes.allSatisfy { $0.terminal.getTerminal().options.scrollback == 3000 }
        let popup = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false; popup.makeKeyAndOrderFront(nil); popup.orderOut(nil)
        checks["newPopupUsesTheme"] = popup.appearance?.name == .darkAqua; popup.close()
        ApplicationAppearance.apply(.system)
        checks["systemModeRemovesOverride"] = controller.window?.appearance == nil
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_APPEARANCE_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print(report); controller.shutdown(); NSApp.terminate(nil)
    }
}
