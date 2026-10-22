// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Keep every toolbar action reachable in the minimum-width window.
final class WorkspaceToolbar: NSStackView {
    static let compactThreshold: CGFloat = 1180
    var compactButtons = [NSButton]()
    override func layout() {
        let position: NSControl.ImagePosition = bounds.width < Self.compactThreshold ? .imageOnly : .imageLeading
        for button in compactButtons where button.imagePosition != position { button.imagePosition = position }
        super.layout()
    }
}

enum WorkspaceToolbarIcon {
    case session, defaults, split
    var image: NSImage {
        let kind = self
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            func line(_ points: [NSPoint]) {
                let path = NSBezierPath(); path.lineWidth = 1.3; path.lineCapStyle = .round; path.lineJoinStyle = .round
                if let first = points.first { path.move(to: first); for point in points.dropFirst() { path.line(to: point) }; path.stroke() }
            }
            if kind == .split {
                let frame = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 18, height: 14), xRadius: 2, yRadius: 2); frame.lineWidth = 1.3; frame.stroke()
                line([NSPoint(x: 10, y: 2), NSPoint(x: 10, y: 16)])
                line([NSPoint(x: 10, y: 9), NSPoint(x: 19, y: 9)])
            } else {
                if kind == .defaults { line([NSPoint(x: 1, y: 5), NSPoint(x: 1, y: 17), NSPoint(x: 15, y: 17)]) }
                let x: CGFloat = kind == .defaults ? 4 : 2
                let frame = NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: 15, height: 13), xRadius: 2, yRadius: 2); frame.lineWidth = 1.3; frame.stroke()
                for (y, knob) in [(CGFloat(10), CGFloat(5)), (CGFloat(5), CGFloat(10))] {
                    line([NSPoint(x: x + 3, y: y), NSPoint(x: x + 12, y: y)])
                    NSBezierPath(roundedRect: NSRect(x: x + knob - 1, y: y - 2, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true; return image
    }
}

extension WorkspaceController {
    func configurePropertyButtons() {
        for (button, title, icon, action) in [
            (currentPropertiesButton, "当前会话属性", WorkspaceToolbarIcon.session, #selector(editCurrentSessionProfile)),
            (defaultPropertiesButton, "默认会话属性", WorkspaceToolbarIcon.defaults, #selector(showSessionDefaults))
        ] {
            button.title = ""; button.image = icon.image; button.imagePosition = .imageOnly
            button.bezelStyle = .texturedRounded; button.target = self; button.action = action
            button.setAccessibilityLabel(title); button.toolTip = title
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        }
        currentPropertiesButton.identifier = .init("toolbar.currentSessionProperties")
        defaultPropertiesButton.identifier = .init("toolbar.defaultSessionProperties")
        defaultPropertiesButton.toolTip = "默认会话属性：用于以后新建的会话"
        splitButton.identifier = .init("toolbar.split"); splitButton.bezelStyle = .texturedRounded
        splitButton.setAccessibilityLabel("分屏"); splitButton.toolTip = "分屏：新建左右或上下终端分屏"
        splitButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let menu = NSMenu(); menu.autoenablesItems = false
        let heading = menu.addItem(withTitle: "", action: nil, keyEquivalent: ""); heading.image = WorkspaceToolbarIcon.split.image
        for (title, action, hint) in [
            ("左右分屏", #selector(splitVertical), "使用当前会话配置新建左右终端分屏"),
            ("上下分屏", #selector(splitHorizontal), "使用当前会话配置新建上下终端分屏"),
            ("放大当前分屏", #selector(togglePaneZoom), "临时放大当前分屏，再次操作恢复布局和比例"),
            ("下一个分屏", #selector(nextPane), "切换到当前标签中的下一个终端"),
            ("上一个分屏", #selector(previousPane), "切换到当前标签中的上一个终端")
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self; item.toolTip = hint
        }
        splitButton.menu = menu
    }
    var canEditCurrentSessionProfile: Bool {
        guard isSecurityUnlocked, let pane = selectedTab?.activePane else { return false }
        return !pane.isBlank && !pane.isShutdown && pane.profile.kind == .ssh
    }
    func refreshUpdateButton() {
        let updater = appUpdater
        updateButton.title = updater.hasPendingInstallation ? "安装更新" : "更新"
        updateButton.setAccessibilityLabel(updater.hasPendingInstallation ? "安装已下载的更新" : "检查更新")
        updateButton.isEnabled = isSecurityUnlocked && updater.canCheck
        updateButton.toolTip = updater.hasPendingInstallation ? "更新已下载，点击确认安装并重启 OShell" : (updater.canCheck ? "检查更新：发现新版本后弹出升级确认窗口" : "正在检查或处理更新，请稍候")
        topToolbar?.needsLayout = true
    }
    func refreshToolbarActions() {
        refreshUpdateButton()
        currentPropertiesButton.isEnabled = canEditCurrentSessionProfile
        currentPropertiesButton.toolTip = canEditCurrentSessionProfile ? "当前会话属性：" + (selectedTab?.activePane.profile.name ?? "") + "（保存后新建连接生效）" : "当前会话属性：请先选择 SSH 会话"
        defaultPropertiesButton.isEnabled = isSecurityUnlocked
        splitButton.isEnabled = isSecurityUnlocked && selectedTab?.activePane.isShutdown == false
        for item in splitButton.menu?.items.dropFirst() ?? [] {
            item.isEnabled = splitButton.isEnabled && validateMenuItem(item)
            if item.action == #selector(togglePaneZoom) { item.toolTip = "临时放大 / 恢复原布局 · " + ShortcutRuntime.hint(.zoomPane) }
        }
    }
    @objc func editCurrentSessionProfile() {
        guard canEditCurrentSessionProfile, let pane = selectedTab?.activePane else { return }
        let source = credentialProfiles.first { $0.id == pane.profile.id } ?? pane.profile
        var titleChoice: (UUID, SessionTitleDisplayMode)?
        guard let profile = Dialogs.session(source, profiles: credentialProfiles, directories: SessionDirectory.all(configuration), defaults: configuration.sessionDefaults, proxies: configuration.proxies, manageProxies: manageProxiesForEditor, titleSelection: { titleChoice = ($0, $1) }) else { return }
        var value = configuration
        if let index = value.profiles.firstIndex(where: { $0.id == source.id }) { value.profiles[index] = profile }
        else { value.profiles.append(profile) }
        if saveConfiguration(value) { saveSessionTitleChoice(titleChoice) }
    }
}
