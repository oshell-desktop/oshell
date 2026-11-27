// SPDX-License-Identifier: GPL-3.0-only
import AppKit

enum WindowLauncherTest {
    static var expected: WindowLauncher? {
        guard ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] != nil,
              let mode = ProcessInfo.processInfo.environment["OSHELL_WINDOW_LAUNCH_MODE"] else { return nil }
        return WindowLauncher(rawValue: mode)
    }

    static func run(_ initial: WorkspaceController, expected: WindowLauncher) {
        let windows = initial.windowCoordinator!
        let delegate = NSApp.delegate as! AppDelegate
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSHELL_WINDOW_LAUNCH_OUTPUT"]!)
        let root = initial.store.url.deletingLastPathComponent()
        var checks = [
            "coldLaunchOverridesDefault": initial.isLocalTerminalWindow == (expected == .localTerminal) &&
                initial.isLocalTerminalWindow != WindowSizePreferences.startWithLocalTerminal,
            "exactlyOneInitialWindow": windows.workspaces.count == 1,
            "protectedWorkspaceAccess": windows.workspaceReady == (expected == .workspace)
        ]
        if expected == .localTerminal { checks["shellIsReady"] = initial.selectedTab?.activePane.connectionIsActive == true }
        DispatchQueue.main.async {
            do {
                let files = try WindowLauncher.export(to: root)
                checks["bothExported"] = files.compactMap(WindowLauncher.init(file:)) == WindowLauncher.exported
                checks["repeatExport"] = try WindowLauncher.export(to: root) == files
                let opposite: WindowLauncher = expected == .workspace ? .localTerminal : .workspace
                let file = files.first { WindowLauncher(file: $0) == opposite }!
                checks["warmLaunchOpensRequestedWindow"] = delegate.application(NSApp, openFile: file.path)
                    && windows.active?.isLocalTerminalWindow == (opposite == .localTerminal) && windows.workspaces.count == 2
                try Data("unrelated content".utf8).write(to: file)
                do { _ = try WindowLauncher.export(to: root); checks["preservesNameCollision"] = false }
                catch { checks["preservesNameCollision"] = try String(contentsOf: file, encoding: .utf8) == "unrelated content" }
                checks["invalidLauncherIgnored"] = !delegate.application(NSApp, openFile: file.path) && windows.workspaces.count == 2
            } catch { checks["exportAndOpen"] = false }
            try! JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks]).write(to: output)
            windows.workspaces.forEach { $0.shutdown() }; NSApp.terminate(nil)
        }
    }
}
