// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// Exercises real navigation and native layout using only disposable configuration.
enum InterfaceDesignTest {
    static func run(_ workspace: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_INTERFACE_DESIGN_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: path)
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func snapshot(_ view: NSView, _ name: String) {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
            let size = view.bounds.size, scale: CGFloat = 2
            guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.scaleBy(x: scale, y: scale)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor); context.fill(view.bounds)
                view.layer?.render(in: context)
            }
            if let image = context.makeImage() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output.deletingPathExtension().appendingPathExtension(name + ".png"))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try? encoder.encode(workspace.configuration)
        let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
            guard let window = NSApp.modalWindow, let root = window.contentView,
                  let tabs = descendants(root).compactMap({ $0 as? NSTabView }).first else { checks["settingsOpened"] = false; NSApp.abortModal(); return }
            checks["settingsUseOpaqueSurface"] = root is InterfaceSurfaceView
            checks["settingsUseCategoryNavigation"] = tabs.tabViewType == .noTabsNoBorder
            let links = descendants(root).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("settings.navigation.") == true }
            checks["allPagesReachable"] = links.count == tabs.numberOfTabViewItems
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                PopupPresentation.applyAppearance(NSAppearance(named: appearance), to: window)
                for item in tabs.tabViewItems {
                    let id = item.identifier as? String ?? ""
                    links.first { $0.identifier?.rawValue == "settings.navigation." + id }?.performClick(nil)
                    root.layoutSubtreeIfNeeded(); window.display()
                    checks[name + "-navigation-" + id] = tabs.selectedTabViewItem === item && links.filter { $0.state == .on }.count == 1
                    checks[name + "-pageCanvas-" + id] = (item.view?.bounds.width ?? 0) >= 820 && (item.view?.bounds.height ?? 0) >= 550
                    if id == "general" || id == "files" { snapshot(root, "settings-" + id + "-" + name) }
                }
            }
            window.setContentSize(NSSize(width: 900, height: 620)); root.layoutSubtreeIfNeeded()
            let card = descendants(root).first { $0.identifier?.rawValue == "settings.page.card" }
            checks["compactSettingsKeepsCardInsideWindow"] = card.map { root.bounds.contains($0.convert($0.bounds, to: root)) } ?? false
            checks["compactSettingsKeepsNavigationReachable"] = links.allSatisfy { $0.bounds.width >= 150 }
            tabs.selectTabViewItem(withIdentifier: "files"); root.layoutSubtreeIfNeeded(); snapshot(root, "settings-compact")
            _ = PopupKeyboard.dismiss(window: window)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        workspace.showPreferences(); timer.invalidate()
        checks["cancelPreservesConfiguration"] = (try? encoder.encode(workspace.configuration)) == original
        workspace.configuration.profiles = [SessionProfile(name: "开发服务器", host: "dev.example.test"), SessionProfile(name: "预发布环境", host: "stage.example.test"), SessionProfile(name: "文件服务器", host: "files.example.test")]
        for index in workspace.configuration.profiles.indices { workspace.configuration.profiles[index].group = "/" }
        let manager = SessionManager(workspace: workspace)
        manager.show()
        if let window = manager.window, let root = window.contentView {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                PopupPresentation.applyAppearance(NSAppearance(named: appearance), to: window)
                snapshot(root, "sessions-" + name)
                checks[name + "-sessionSurface"] = root is InterfaceSurfaceView
            }
        }
        manager.close()
        PopupPresentation.applyAppearance(NSAppearance(named: .aqua), to: workspace.window!)
        if let root = workspace.window?.contentView { snapshot(root, "workspace") }
        try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
