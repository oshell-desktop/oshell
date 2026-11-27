// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Drive key equivalents inside the disposable build without requiring system
/// Accessibility access to send keystrokes to other applications.
enum LocalDockShortcutTest {
    static func install(workspace: WorkspaceController? = nil) {
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier?.hasPrefix("app.oshell.ui-test.") == true,
              let root = env["OSHELL_DOCK_TEST_ROOT"], env["OSHELL_DATA_DIR"] == root else { return }
        let directory = URL(fileURLWithPath: root)
        if let workspace {
            let change = directory.appendingPathComponent("font-change")
            Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                guard let kind = try? String(contentsOf: change, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: change)
                var value = workspace.configuration
                switch kind {
                case "size": value.preferences.fontSize = 20
                case "face": value.preferences.fontName = "DejaVuSansMono"
                case "default": value.preferences.fontName = ""
                default: return
                }
                _ = workspace.saveConfiguration(value)
            }
            return
        }
        let request = directory.appendingPathComponent("shortcut")
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.windowController is WorkspaceController }),
                  let key = try? String(contentsOf: request, encoding: .utf8), ["t", "N", "theme", "font", "exit-shells"].contains(key) else { return }
            try? FileManager.default.removeItem(at: request)
            if key == "exit-shells" {
                for controller in NSApp.windows.compactMap({ $0.windowController as? WorkspaceController }) {
                    for pane in controller.inputPanes { pane.terminal.process.send(data: Array("exit\r".utf8)[...]) }
                }
                return
            }
            if key == "font" {
                let faces = NSApp.windows.compactMap { $0.windowController as? WorkspaceController }
                    .flatMap { $0.inputPanes.map { "\($0.terminal.font.fontName)@\(Int($0.terminal.font.pointSize))" } }
                try? faces.joined(separator: ",").write(to: directory.appendingPathComponent("shortcut-result"), atomically: true, encoding: .utf8)
                return
            }
            if key == "theme" {
                let colors = NSApp.windows.compactMap { $0.windowController as? WorkspaceController }
                    .flatMap { $0.inputPanes.map { $0.terminal.nativeBackgroundColor.rgbHex } }
                let result = ApplicationAppearance.theme.rawValue + ":" + colors.joined(separator: ",")
                try? result.write(to: request.deletingLastPathComponent().appendingPathComponent("shortcut-result"), atomically: true, encoding: .utf8)
                return
            }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: key == "t" ? [.command] : [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "t" ? 17 : 45)!
            // A test window can be visible while the user's foreground app owns
            // key focus. Resolve the installed key equivalent through its actual
            // menu target in that case, without injecting keys into the desktop.
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
            let item = items.first { $0.keyEquivalent == key.lowercased() && $0.keyEquivalentModifierMask == flags }
            var handled = false
            if let item, let action = item.action {
                if window.isKeyWindow, let controller = window.windowController as? WorkspaceController,
                   let shortcut = ShortcutRuntime.current.action(for: .init(event: event)) {
                    handled = controller.dispatchShortcut(shortcut)
                } else {
                    handled = NSApp.sendAction(action, to: item.target, from: item)
                }
            }
            let result = request.deletingLastPathComponent().appendingPathComponent("shortcut-result")
            try? (handled ? key : "unhandled " + key).write(to: result, atomically: true, encoding: .utf8)
        }
    }
}
