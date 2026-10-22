// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Carbon
import OShellCore

extension KeyboardShortcut {
    init(event: NSEvent) {
        var flags = 0
        for (native, bit) in [(NSEvent.ModifierFlags.command, Self.command), (.option, Self.option), (.control, Self.control), (.shift, Self.shift)] where event.modifierFlags.contains(native) { flags |= bit }
        self.init(event.keyCode, flags)
    }
    var nativeModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for (native, bit) in [(NSEvent.ModifierFlags.command, Self.command), (.option, Self.option), (.control, Self.control), (.shift, Self.shift)] where modifiers & bit != 0 { flags.insert(native) }
        return flags
    }
}
extension ShortcutAction {
    var selector: Selector {
        if number != nil { return #selector(WorkspaceController.selectNumberedTab(_:)) }
        switch self {
        case .newWindow: return #selector(WorkspaceController.newWindow)
        case .settings: return #selector(WorkspaceController.showPreferences)
        case .sessionManager: return #selector(WorkspaceController.showSessionManager)
        case .connectSelected: return #selector(WorkspaceController.connectSelected)
        case .newSession: return #selector(WorkspaceController.newSession)
        case .newBlank: return #selector(WorkspaceController.newBlankTab)
        case .local: return #selector(WorkspaceController.newLocal)
        case .currentProperties: return #selector(WorkspaceController.editCurrentSessionProfile)
        case .liveProperties: return #selector(WorkspaceController.showCurrentSessionProperties)
        case .defaults: return #selector(WorkspaceController.showSessionDefaults)
        case .importSessions: return #selector(WorkspaceController.importSessions)
        case .exportSessions: return #selector(WorkspaceController.exportSessions)
        case .reconnect: return #selector(WorkspaceController.reconnect)
        case .closePane: return #selector(WorkspaceController.closePane)
        case .closeTab: return #selector(WorkspaceController.closeTab)
        case .copy: return #selector(NSText.copy(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSText.selectAll(_:))
        case .find: return #selector(WorkspaceController.findInTerminal)
        case .findNext: return #selector(WorkspaceController.findNextInTerminal)
        case .findPrevious: return #selector(WorkspaceController.findPreviousInTerminal)
        case .splitVertical: return #selector(WorkspaceController.splitVertical)
        case .splitHorizontal: return #selector(WorkspaceController.splitHorizontal)
        case .focusFullscreen: return #selector(WorkspaceController.toggleFocusFullscreen)
        case .zoomPane: return #selector(WorkspaceController.togglePaneZoom)
        case .nextPane: return #selector(WorkspaceController.nextPane)
        case .previousPane: return #selector(WorkspaceController.previousPane)
        case .quickSwitch: return #selector(WorkspaceController.showQuickSessionSwitcher)
        case .logging: return #selector(WorkspaceController.toggleLogging)
        case .nextTab: return #selector(WorkspaceController.nextTab)
        case .previousTab: return #selector(WorkspaceController.previousTab)
        case .recentTab: return #selector(WorkspaceController.lastUsedTab)
        case .tabNumber: return #selector(WorkspaceController.chooseTabNumber)
        case .newGroup: return #selector(WorkspaceController.newNamedTabGroup)
        case .showGroups: return #selector(WorkspaceController.showAllTabGroups)
        case .arrangeTabs, .arrangeHorizontal, .arrangeVertical, .arrangeTiled: return #selector(WorkspaceController.changeArrangement(_:))
        case .sessionSidebar: return #selector(WorkspaceController.toggleSessionSidebar)
        case .links: return #selector(WorkspaceController.toggleSessionLinkBar)
        case .quickSend: return #selector(WorkspaceController.toggleQuickSendBar)
        case .focusQuickSend: return #selector(WorkspaceController.focusQuickSendBar)
        case .composer: return #selector(WorkspaceController.toggleComposer)
        case .syncInput: return #selector(WorkspaceController.configureSyncInput)
        case .stopSync: return #selector(WorkspaceController.stopSyncInput)
        case .files: return #selector(WorkspaceController.showFiles)
        case .quickCommands: return #selector(WorkspaceController.showQuickCommands)
        case .highlights: return #selector(WorkspaceController.showHighlights)
        case .appearance: return #selector(WorkspaceController.showAppearancePreferences)
        case .hide: return #selector(NSApplication.hide(_:))
        case .quit: return #selector(NSApplication.terminate(_:))
        case .minimize: return #selector(NSWindow.performMiniaturize(_:))
        default: return #selector(WorkspaceController.selectNumberedTab(_:))
        }
    }
    var tag: Int {
        if let number { return number }
        switch self { case .arrangeHorizontal: return 1; case .arrangeVertical: return 2; case .arrangeTiled: return 3; default: return 0 }
    }
    static func identify(_ item: NSMenuItem) -> ShortcutAction? { allCases.first { $0.selector == item.action && ($0.number == nil && ![.arrangeTabs,.arrangeHorizontal,.arrangeVertical,.arrangeTiled].contains($0) || $0.tag == item.tag) } }
}

enum ShortcutRuntime {
    static var current = KeyboardShortcuts()
    static func install(_ shortcuts: KeyboardShortcuts, menu: NSMenu? = NSApp.mainMenu) {
        let shortcuts = SessionSidebarPreferences.shortcuts(shortcuts)
        current = shortcuts
        NSMenuItem.usesUserKeyEquivalents = false // App-local: the in-app configuration owns menu bindings.
        func update(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == #selector(WorkspaceController.toggleDeepFocus) {
                    let binding = WorkspaceController.deepFocusShortcut
                    item.keyEquivalent = shortcuts.action(for: binding) == nil ? "f" : ""
                    item.keyEquivalentModifierMask = binding.nativeModifiers
                }
                if let action = ShortcutAction.identify(item) {
                    item.identifier = .init("shortcut." + action.rawValue)
                    let binding = shortcuts.bindings(for: action).first
                    item.keyEquivalent = binding?.key?.equivalent ?? ""
                    item.keyEquivalentModifierMask = binding?.nativeModifiers ?? []
                }
                if let child = item.submenu { update(child) }
            }
        }
        if let menu { update(menu) }
    }
    static func matches(_ action: ShortcutAction, event: NSEvent) -> Bool { current.action(for: .init(event: event)) == action }
    static func hint(_ action: ShortcutAction) -> String { current.bindings(for: action).first?.display ?? "未设置快捷键" }
}
extension WorkspaceController {
    @discardableResult func dispatchShortcut(_ action: ShortcutAction) -> Bool {
        let item = NSMenuItem(title: action.title, action: action.selector, keyEquivalent: ""); item.tag = action.tag
        switch action {
        case .copy, .paste, .selectAll, .minimize: _ = NSApp.sendAction(action.selector, to: nil, from: item)
        case .hide, .quit: _ = NSApp.sendAction(action.selector, to: NSApp, from: item)
        default:
            // Recognized but unavailable actions are consumed, never typed into the PTY.
            guard validateMenuItem(item) else { return true }
            _ = NSApp.sendAction(action.selector, to: self, from: item)
        }
        return true
    }
}

struct ShortcutSystemConflicts {
    var enabled = Set<KeyboardShortcut>()
    var readable = true
    var menuEquivalents = [KeyboardShortcut: String]()
    static func load() -> Self {
        // CarbonEvents.h: this is a main-thread-only snapshot; never poll on key presses.
        var array: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&array)
        let list = array?.takeRetainedValue() as? [[String: Any]]
        var result = fromRecords(list ?? [])
        result.readable = status == noErr && list != nil
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSUserKeyEquivalents"] as? [String: String] ?? [:]
        let local = UserDefaults.standard.dictionary(forKey: "NSUserKeyEquivalents") as? [String: String] ?? [:]
        for (title, specification) in global.merging(local, uniquingKeysWith: { _, new in new }) {
            if let shortcut = decodeMenuShortcut(specification) { result.menuEquivalents[shortcut] = String(title.prefix(80)) }
        }
        return result
    }
    static func decodeMenuShortcut(_ specification: String) -> KeyboardShortcut? {
        var flags = 0, characters = specification[...]
        let markers: [Character: Int] = ["@":KeyboardShortcut.command, "~":KeyboardShortcut.option, "^":KeyboardShortcut.control, "$":KeyboardShortcut.shift]
        while let first = characters.first, let bit = markers[first] { flags |= bit; characters.removeFirst() }
        let text = String(characters)
        guard text.count == 1, let key = ShortcutKey.all.first(where: { $0.equivalent == text.lowercased() }) else { return nil }
        if text != text.lowercased() { flags |= KeyboardShortcut.shift }
        return .init(key.code, flags)
    }
    static func fromRecords(_ list: [[String: Any]]) -> Self {
        var result = Self()
        for record in list where (record[kHISymbolicHotKeyEnabled as String] as? Bool) == true {
            guard let code = record[kHISymbolicHotKeyCode as String] as? NSNumber, let modifiers = record[kHISymbolicHotKeyModifiers as String] as? NSNumber else { continue }
            let raw = modifiers.intValue
            var flags = 0
            for (carbon, bit) in [(cmdKey, KeyboardShortcut.command), (optionKey, KeyboardShortcut.option), (controlKey, KeyboardShortcut.control), (shiftKey, KeyboardShortcut.shift)] where raw & Int(carbon) != 0 { flags |= bit }
            result.enabled.insert(.init(code.uint16Value, flags))
        }
        return result
    }
    func conflict(_ shortcut: KeyboardShortcut) -> String? {
        if enabled.contains(shortcut) { return "与已启用的 macOS 系统快捷键冲突" }
        if let title = menuEquivalents[shortcut] { return "与系统应用快捷键“" + title + "”冲突" }
        let cmd = KeyboardShortcut.command, opt = KeyboardShortcut.option, shift = KeyboardShortcut.shift, ctrl = KeyboardShortcut.control
        if [KeyboardShortcut(48,cmd), .init(48,cmd|shift), .init(53,cmd|opt), .init(12,cmd|ctrl)].contains(shortcut) { return "与 macOS 应用切换、强制退出或锁屏快捷键冲突" }
        if [KeyboardShortcut(7,cmd), .init(6,cmd), .init(6,cmd|shift)].contains(shortcut) { return "与文本编辑的剪切、撤销或重做快捷键冲突" }
        return nil
    }
}
