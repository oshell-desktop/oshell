// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Prefer labels when space permits; actions also remain in the app menus.
final class WorkspaceToolbar: NSStackView {
    static let compactThreshold: CGFloat = 1180
    var compactButtons = [NSButton]()
    func showButtonLabels(_ visible: Bool) {
        let position: NSControl.ImagePosition = visible ? .imageLeading : .imageOnly
        for button in compactButtons where button.imagePosition != position { button.imagePosition = position }
    }
}

/// Small windows reclaim the toolbar row instead of scrolling its controls.
final class WorkspaceToolbarHost: NSScrollView {
    static let minimumWidth: CGFloat = 980
    static let minimumHeight: CGFloat = 500
    static let restoreMargin: CGFloat = 48
    private(set) var isMinimal = false
    var focusMode = false { didSet { refreshPresentation() } }
    lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 40)
    private var previousWidth: CGFloat?
    init(_ toolbar: WorkspaceToolbar) {
        super.init(frame: .zero)
        drawsBackground = false; hasHorizontalScroller = false; hasVerticalScroller = false
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        toolbar.translatesAutoresizingMaskIntoConstraints = true
        documentView = toolbar
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        refreshPresentation()
    }
    func refreshPresentation() {
        guard let toolbar = documentView as? WorkspaceToolbar else { return }
        let size = window?.contentView?.bounds.size ?? bounds.size
        guard size.width > 0 else { return }
        // Retry labels only after a width change, avoiding repeated label/icon
        // toggles during AppKit's layout passes at the same window size.
        if previousWidth != size.width {
            previousWidth = size.width
            toolbar.showButtonLabels(size.width >= WorkspaceToolbar.compactThreshold)
        }
        if toolbar.fittingSize.width > size.width { toolbar.showButtonLabels(false) }
        let neededWidth = max(Self.minimumWidth, toolbar.fittingSize.width)
        let margin = isMinimal ? Self.restoreMargin : 0
        isMinimal = size.width < neededWidth + margin || size.height < Self.minimumHeight + margin
        let collapsed = isMinimal || focusMode
        if toolbar.isHidden != collapsed { toolbar.isHidden = collapsed }
        let height: CGFloat = collapsed ? 0 : 40
        if heightConstraint.constant != height { heightConstraint.constant = height }
        let frame = NSRect(x: 0, y: 0, width: max(size.width, toolbar.fittingSize.width), height: 40)
        if toolbar.frame != frame { toolbar.frame = frame }
        if contentView.bounds.origin != .zero { contentView.scroll(to: .zero) }
    }
}

enum WorkspaceToolbarIcon: String, CaseIterable {
    case sidebar = "sidebar.left"
    case catalog = "server.rack"
    case quickConnect = "bolt.fill"
    case newSession = "plus.rectangle"
    case local = "terminal"
    case files = "folder"
    case session = "macwindow"
    case defaults = "gearshape.2"
    case split = "rectangle.split.2x1"
    case tabGroups = "rectangle.stack"
    case groupArrangement = "rectangle.3.group"
    case paneArrangement = "rectangle.split.2x2"
    case tools = "wrench.and.screwdriver"
    case search = "magnifyingglass"
    case record = "record.circle"
    case stopRecording = "stop.circle"
    case mcp = "puzzlepiece.extension"
    case proxy = "network"
    case update = "arrow.down.circle"
    case installUpdate = "arrow.down.circle.fill"
    case settings = "gearshape"

    // Rebuilding session/group menus reuses the same template images.
    private static let images: [Self: NSImage] = Dictionary(uniqueKeysWithValues: allCases.map { icon in
        let symbol = NSImage(systemSymbolName: icon.rawValue, accessibilityDescription: nil)
            ?? NSImage(named: NSImage.actionTemplateName)!
        var image = symbol.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? symbol
        if icon == .session {
            let window = image
            let gear = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)!
            image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
                window.draw(in: NSRect(x: 0, y: 3, width: 19, height: 15))
                NSGraphicsContext.current?.cgContext.clear(CGRect(x: 11, y: 0, width: 11, height: 11))
                gear.draw(in: NSRect(x: 12, y: 0, width: 10, height: 10)); return true
            }
        }
        image.isTemplate = true
        return (icon, image)
    })
    var image: NSImage { Self.images[self]! }
}

extension WorkspaceController {
    func configurePropertyButtons() {
        sessionPropertiesControl.editCurrent = { [weak self] in self?.editCurrentSessionProfile() }
        sessionPropertiesControl.updateMenu = { [weak self] menu in self?.populateSessionPropertiesMenu(menu) }
        sessionPropertiesControl.refreshMenu()
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
        updateButton.image = (updater.hasPendingInstallation ? WorkspaceToolbarIcon.installUpdate : .update).image
        updateButton.setAccessibilityLabel(updater.hasPendingInstallation ? "安装已下载的更新" : "检查更新")
        updateButton.isEnabled = isSecurityUnlocked && updater.canCheck
        updateButton.toolTip = updater.hasPendingInstallation ? "更新已下载，点击确认安装并重启 OShell" : (updater.canCheck ? "检查更新：发现新版本后弹出升级确认窗口" : "正在检查或处理更新，请稍候")
        topToolbar?.needsLayout = true
        topToolbar?.enclosingScrollView?.needsLayout = true
    }
    func refreshToolbarActions() {
        refreshGlobalProxyButton()
        refreshUpdateButton()
        sessionPropertiesControl.isEnabled = isSecurityUnlocked
        sessionPropertiesControl.setEnabled(canEditCurrentSessionProfile, forSegment: 0)
        sessionPropertiesControl.setEnabled(isSecurityUnlocked, forSegment: 1)
        sessionPropertiesControl.setToolTip(canEditCurrentSessionProfile ? "编辑当前会话属性：" + (selectedTab?.activePane.profile.name ?? "") : "请先选择 SSH 会话；箭头菜单仍可编辑默认或其他会话", forSegment: 0)
        splitButton.isEnabled = isSecurityUnlocked && selectedTab?.activePane.isShutdown == false
        for item in splitButton.menu?.items.dropFirst() ?? [] {
            item.isEnabled = splitButton.isEnabled && validateMenuItem(item)
            if item.action == #selector(togglePaneZoom) { item.toolTip = "临时放大 / 恢复原布局 · " + ShortcutRuntime.hint(.zoomPane) }
        }
    }
    @objc func editCurrentSessionProfile() {
        guard canEditCurrentSessionProfile, let pane = selectedTab?.activePane else { return }
        if pane.sshConnectionGroup?.isExternal == true {
            showCurrentSessionProperties()
            return
        }
        let source = credentialProfiles.first { $0.id == pane.profile.id } ?? pane.profile
        var titleChoice: (UUID, SessionTitleDisplayMode)?
        guard let profile = Dialogs.session(source, profiles: credentialProfiles, directories: SessionDirectory.all(configuration), defaults: configuration.sessionDefaults, proxies: configuration.proxies, manageProxies: manageProxiesForEditor, titleSelection: { titleChoice = ($0, $1) }) else { return }
        var value = configuration
        if let index = value.profiles.firstIndex(where: { $0.id == source.id }) { value.profiles[index] = profile }
        else { value.profiles.append(profile) }
        if saveConfiguration(value) { saveSessionTitleChoice(titleChoice) }
    }
}
