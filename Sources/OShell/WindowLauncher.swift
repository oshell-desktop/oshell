// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum WindowLauncher: String {
    case localTerminal = "local-terminal"
    case workspace
    case focusWorkspace = "focus-workspace"

    static let exported: [WindowLauncher] = [.localTerminal, .workspace]

    var title: String {
        self == .localTerminal ? "oTerm" : "OShell 会话工作区"
    }

    init?(file: URL) {
        guard file.isFileURL, file.pathExtension.lowercased() == "oshellwindow",
              let data = try? SharedDataFile.readIfPresent(file, maximumSize: 32),
              let value = String(data: data, encoding: .utf8) else { return nil }
        self.init(rawValue: value.trimmingCharacters(in: .newlines))
    }

    @discardableResult static func export(to directory: URL) throws -> [URL] {
        var urls = [URL]()
        for mode in exported {
            let url = directory.appendingPathComponent(mode.title + ".oshellwindow")
            if WindowLauncher(file: url) != mode {
                try Data((mode.rawValue + "\n").utf8).write(to: url, options: .withoutOverwriting)
            }
            urls.append(url)
        }
        return urls
    }
}

/// Both apps address a specific bundle; the system's default document handler
/// stays with OShell so previously exported Finder entries keep working.
enum OShellAppPair {
    static let terminalFilename = "oTerm.app"
    static let previousTerminalFilename = "OShell 本地终端.app"
    static let ownsLocalWindows = Bundle.main.object(forInfoDictionaryKey: "OShellOwnsLocalWindows") as? Bool == true

    static func peer(terminal: Bool) -> Bundle? {
        guard Bundle.main.object(forInfoDictionaryKey: "OShellTestHarness") == nil,
              let identifier = Bundle.main.object(forInfoDictionaryKey: terminal ? "OShellLocalTerminalBundleIdentifier" : "OShellHostBundleIdentifier") as? String else { return nil }
        let name = terminal ? terminalFilename : "OShell.app"
        let locations = [Bundle.main.bundleURL.deletingLastPathComponent(), URL(fileURLWithPath: "/Applications")]
        var urls = locations.map { $0.appendingPathComponent(name) }
        if terminal { urls += locations.map { $0.appendingPathComponent(previousTerminalFilename) } }
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { urls.append(registered) }
        return urls.compactMap(Bundle.init(url:)).first { bundle in
            guard bundle.bundleIdentifier == identifier, bundle.object(forInfoDictionaryKey: "OShellTestHarness") == nil else { return false }
            if terminal {
                return bundle.object(forInfoDictionaryKey: "OShellOwnsLocalWindows") as? Bool == true &&
                    bundle.object(forInfoDictionaryKey: "OShellHostBundleIdentifier") as? String == Bundle.main.bundleIdentifier
            }
            return true
        }
    }

    static func open(_ urls: [URL], in app: Bundle, completion: (() -> Void)? = nil) {
        NSWorkspace.shared.open(urls, withApplicationAt: app.bundleURL, configuration: .init()) { _, error in
            DispatchQueue.main.async {
                if let error { Dialogs.message("打开" + app.bundleURL.deletingPathExtension().lastPathComponent + "失败：" + error.localizedDescription) }
                completion?()
            }
        }
    }

    static func showWorkspace() {
        guard let app = peer(terminal: false) else {
            Dialogs.message("找不到 OShell。请将 OShell.app 与本地终端放在同一文件夹。"); return
        }
        let mode: WindowLauncher = app.object(forInfoDictionaryKey: "OShellLocalTerminalBundleIdentifier") == nil ? .workspace : .focusWorkspace
        guard let request = Bundle.main.url(forResource: mode.rawValue, withExtension: "oshellwindow") else {
            Dialogs.message("缺少工作区启动文件，请重新安装 oTerm。"); return
        }
        open([request], in: app)
    }
}
