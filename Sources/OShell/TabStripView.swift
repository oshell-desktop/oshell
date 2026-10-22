// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// A bounded tab strip. The document owns its width instead of relying on the
/// intrinsic size of a stack view inside an unconstrained clip view.
final class TabStripView: InterfaceSurfaceView {
    static let barHeight: CGFloat = 30
    enum ConnectionStatus: Equatable {
        case disconnected, connecting, connected, commandConnection
        var title: String { switch self { case .disconnected: return "未连接 / 已断开"; case .connecting: return "正在连接 / 等待认证"; case .connected: return "已连接"; case .commandConnection: return "命令行连接运行中" } }
        var color: NSColor { self == .disconnected ? .systemRed : .systemGreen }
    }
    class MenuButton: NSButton {
        var makeMenu: (() -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    }
    private final class MenuPopUp: NSPopUpButton {
        var makeMenu: (() -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    }
    private final class Clip: NSClipView {
        var makeMenu: (() -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    }
    private final class Scroll: NSScrollView {
        var makeMenu: (() -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
        override func scrollWheel(with event: NSEvent) {
            guard let documentView else { return }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            let limit = max(0, documentView.bounds.width - contentView.bounds.width)
            let x = min(limit, max(0, contentView.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : 16)))
            contentView.scroll(to: NSPoint(x: x, y: 0)); reflectScrolledClipView(contentView)
        }
    }
    private final class Document: NSView {
        var makeMenu: (() -> NSMenu?)?
        override var isFlipped: Bool { true }
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    }
    final class Item: NSView, NSDraggingSource {
        final class TitleButton: MenuButton {
            var trackDrag: ((NSEvent) -> Bool)?
            var onDoubleClick: (() -> Void)?
            var onHoverEnter: (() -> Void)?, onHoverExit: (() -> Void)?, onPress: (() -> Void)?
            private var hoverTracking: NSTrackingArea?
            override func updateTrackingAreas() {
                if let hoverTracking { removeTrackingArea(hoverTracking) }
                let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
                addTrackingArea(tracking); hoverTracking = tracking; super.updateTrackingAreas()
            }
            override func mouseEntered(with event: NSEvent) { onHoverEnter?() }
            override func mouseExited(with event: NSEvent) { onHoverExit?() }
            override func mouseDown(with event: NSEvent) {
                onPress?()
                if event.clickCount == 2, !event.modifierFlags.contains(.control) { onDoubleClick?(); return }
                if trackDrag?(event) == true { return }; super.mouseDown(with: event)
            }
        }
        let id: UUID
        let selectButton = TitleButton()
        let closeButton = MenuButton()
        var onSelect: (() -> Void)?
        var onClose: (() -> Void)?
        var onDuplicate: (() -> Void)?
        var makeMenu: (() -> NSMenu?)?
        var dragEnabled = false
        var onDragEnd: (() -> Void)?
        var onDragCompletion: ((NSPoint, NSDragOperation, Bool) -> Void)?
        var sessionFields = [TabSessionField]() { didSet { if oldValue != sessionFields { dismissSessionInfo() } } }
        var hoverDetail = "" { didSet { if oldValue != hoverDetail { dismissSessionInfo() } } }
        private(set) var sessionInfo: TabSessionInfoPanel?
        private var hoverTimer: Timer?
        func scheduleSessionInfo() {
            hoverTimer?.invalidate()
            guard !sessionFields.isEmpty else { return }
            let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self, let window = self.window, NSApp.isActive, window.isKeyWindow, NSEvent.pressedMouseButtons == 0,
                      self.selectButton.bounds.contains(self.selectButton.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) else { return }
                self.showSessionInfo()
            }
            hoverTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        func delayDismissSessionInfo() {
            hoverTimer?.invalidate()
            let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in self?.dismissSessionInfo() }
            hoverTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        func dismissSessionInfo() { hoverTimer?.invalidate(); hoverTimer = nil; sessionInfo?.close(); sessionInfo = nil }
        func showSessionInfo() {
            dismissSessionInfo()
            guard !sessionFields.isEmpty, window != nil else { return }
            let info = TabSessionInfoPanel(title: selectButton.title, fields: sessionFields, details: hoverDetail)
            info.onEnter = { [weak self] in self?.hoverTimer?.invalidate(); self?.hoverTimer = nil }
            info.onExit = { [weak self] in self?.delayDismissSessionInfo() }
            info.onClose = { [weak self, weak info] in
                if self?.sessionInfo === info { self?.sessionInfo = nil }
            }
            sessionInfo = info; info.show(relativeTo: selectButton)
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { dismissSessionInfo() } }
        override func viewDidHide() { super.viewDidHide(); dismissSessionInfo() }
        private var dragEventMonitor: Any?
        private var dragCancelled = false
        private var dragOriginFrame: NSRect?
        private func clearDragMonitor() {
            if let dragEventMonitor { NSEvent.removeMonitor(dragEventMonitor) }
            dragEventMonitor = nil
        }
        deinit { clearDragMonitor(); hoverTimer?.invalidate(); sessionInfo?.close() }
        func track(_ event: NSEvent) -> Bool {
            dismissSessionInfo()
            guard dragEnabled, !event.modifierFlags.contains(.control), event.clickCount == 1, let window else { return false }
            let start = event.locationInWindow
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { onSelect?(); return true }
                let point = next.locationInWindow
                if hypot(point.x - start.x, point.y - start.y) < 5 { continue }
                let pasteboard = NSPasteboardItem(); pasteboard.setString(id.uuidString, forType: TabDropHost.pasteboardType)
                let item = NSDraggingItem(pasteboardWriter: pasteboard)
                let image = NSImage(size: bounds.size); image.lockFocus()
                NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: 4, yRadius: 4).fill()
                (selectButton.title as NSString).draw(at: NSPoint(x: 10, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]); image.unlockFocus()
                item.setDraggingFrame(bounds, contents: image)
                clearDragMonitor(); dragCancelled = false; dragOriginFrame = window.frame
                dragEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { self?.dragCancelled = true }
                    return event // AppKit still handles cancellation of its native drag session.
                }
                beginDraggingSession(with: [item], event: next, source: self); return true
            }
            return true
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            if onDragCompletion != nil, let frame = dragOriginFrame {
                session.animatesToStartingPositionsOnCancelOrFail = frame.insetBy(dx: -12, dy: -12).contains(screenPoint)
            }
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            let escape = NSApp.currentEvent.map { $0.type == .keyDown && $0.keyCode == 53 } ?? false
            // A cancelled native drag also reports .none. Never interpret Escape
            // or cancellation while the button is still held as a detached tab.
            let cancelled = dragCancelled || escape || NSEvent.pressedMouseButtons & 1 != 0
            finishDragging(at: screenPoint, operation: operation, cancelled: cancelled)
        }
        func finishDragging(at screenPoint: NSPoint, operation: NSDragOperation, cancelled: Bool) {
            clearDragMonitor(); dragOriginFrame = nil; dragCancelled = false
            onDragEnd?(); onDragCompletion?(screenPoint, operation, cancelled)
        }
        var selected = false { didSet { needsDisplay = true } }
        var hasUnreadOutput = false { didSet { if oldValue != hasUnreadOutput { needsDisplay = true } } }
        var connectionStatus: ConnectionStatus? { didSet { if oldValue != connectionStatus { needsDisplay = true } } }
        var preferredWidth: CGFloat = 160
        init(id: UUID) {
            self.id = id
            super.init(frame: .zero)
            selectButton.isBordered = false
            selectButton.font = .systemFont(ofSize: 12, weight: .medium)
            selectButton.alignment = .left; selectButton.lineBreakMode = .byTruncatingTail
            selectButton.target = self; selectButton.action = #selector(selectItem)
            selectButton.makeMenu = { [weak self] in self?.dismissSessionInfo(); return self?.makeMenu?() }
            selectButton.onHoverEnter = { [weak self] in self?.scheduleSessionInfo() }
            selectButton.onHoverExit = { [weak self] in self?.delayDismissSessionInfo() }
            selectButton.onPress = { [weak self] in self?.dismissSessionInfo() }
            selectButton.trackDrag = { [weak self] in self?.track($0) ?? false }
            selectButton.onDoubleClick = { [weak self] in self?.onDuplicate?() }
            closeButton.isBordered = false
            closeButton.image = NSImage(oshellSymbolName: "xmark", accessibilityDescription: "关闭标签")
            closeButton.imageScaling = .scaleProportionallyDown
            closeButton.target = self; closeButton.action = #selector(closeItem)
            closeButton.makeMenu = { [weak self] in self?.makeMenu?() }
            addSubview(selectButton); addSubview(closeButton)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            selectButton.frame = NSRect(x: 18, y: 0, width: max(0, bounds.width - 48), height: bounds.height)
            closeButton.frame = NSRect(x: bounds.width - 26, y: 0, width: 22, height: bounds.height)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.labelColor.withAlphaComponent(selected ? 0.075 : 0.02).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
            if selected {
                TerminalChrome.flame.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: 2), xRadius: 1, yRadius: 1).fill()
            }
            if let connectionStatus {
                connectionStatus.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 9, y: floor((bounds.height - 6) / 2), width: 6, height: 6)).fill()
            } else if hasUnreadOutput {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: 9, y: floor((bounds.height - 6) / 2), width: 6, height: 6)).fill()
            }
        }
        @objc private func selectItem() { onSelect?() }
        @objc private func closeItem() { onClose?() }
        override func mouseDown(with event: NSEvent) { if track(event) { return }; if event.clickCount == 2 { onDuplicate?() } else { onSelect?() } }
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    }
    private final class InsertionMarker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            TerminalChrome.flame.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
        }
    }
    private let insertionMarker = InsertionMarker()
    private var lastDragScroll: TimeInterval = 0
    var canAcceptTab: ((UUID) -> Bool)?
    /// The destination is an existing tab's UUID, or nil for the end of this strip.
    var onReorderTab: ((UUID, UUID?) -> Bool)?
    var onDragOver: (() -> Void)?
    private let scroll = Scroll()
    private let document = Document()
    private let addButton = MenuButton()
    private let groupButton = MenuPopUp(frame: .zero, pullsDown: true)
    private var groupWidth: CGFloat = 0
    var backgroundMenu: (() -> NSMenu?)?
    private let listButton = MenuPopUp(frame: .zero, pullsDown: true)
    private(set) var items = [Item]()
    private var selectedID: UUID?
    private var displayedEntries: [Entry]?
    private var displayedShortcuts: KeyboardShortcuts?
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onDuplicate: ((UUID) -> Void)?
    var onAdd: (() -> Void)?
    var contextMenu: ((UUID) -> NSMenu?)?
    var allowsTabDragging = false
    var onDragEnd: (() -> Void)?
    var onDragCompletion: ((UUID, NSPoint, NSDragOperation, Bool) -> Void)?
    var canAcceptExternalTab: ((UUID, NSWindow) -> Bool)?
    var onExternalTabDrop: ((UUID, NSWindow, UUID?) -> Bool)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([TabDropHost.pasteboardType])
        // No reserved scroller track, including macOS's “Always” preference.
        // Wheel/trackpad, keyboard navigation and the all-tabs menu remain available.
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        let clip = Clip(); clip.drawsBackground = false; scroll.contentView = clip
        let background: () -> NSMenu? = { [weak self] in self?.backgroundMenu?() }
        scroll.makeMenu = background; clip.makeMenu = background; document.makeMenu = background
        addButton.makeMenu = background; groupButton.makeMenu = background; listButton.makeMenu = background
        scroll.documentView = document
        addButton.image = NSImage(oshellSymbolName: "plus", accessibilityDescription: "新建本地标签")
        addButton.isBordered = false; addButton.toolTip = "新建本地标签"
        addButton.target = self; addButton.action = #selector(addTab)
        listButton.isBordered = false; listButton.toolTip = "所有标签"
        listButton.setAccessibilityLabel("所有标签")
        groupButton.isBordered = false; groupButton.font = .systemFont(ofSize: 11, weight: .semibold); groupButton.isHidden = true
        [scroll, groupButton, addButton, listButton].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func menu(for event: NSEvent) -> NSMenu? { backgroundMenu?() }
    func setGroup(title: String, menu: NSMenu, active: Bool, unread: Bool) {
        groupButton.isHidden = false
        let caption = (unread ? "● " : "") + title
        menu.insertItem(NSMenuItem(title: caption, action: nil, keyEquivalent: ""), at: 0)
        groupButton.menu = menu; groupButton.toolTip = title + " · 标签组操作"
        groupButton.setAccessibilityLabel("标签组 " + title)
        groupButton.oshellContentTintColor = unread ? .systemOrange : (active ? .oshellAccentColor : .labelColor)
        groupWidth = min(120, max(76, (caption as NSString).size(withAttributes: [.font: groupButton.font!]).width + 24))
        needsLayout = true
    }
    struct Entry: Equatable {
        let id: UUID
        let title: String
        let detail: String
        var hasUnreadOutput = false
        var number: Int? = nil
        var connectionStatus: ConnectionStatus? = nil
        var sessionFields = [TabSessionField]()
    }
    func setAddDescription(_ title: String) { addButton.toolTip = title; addButton.setAccessibilityLabel(title) }
    func update(tabs: [TerminalTab], selected: TerminalTab?, numbers: [UUID: Int]? = nil) {
        let numbers = numbers ?? Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset + 1) })
        update(entries: tabs.map { tab in
            let title = tab.title
            let action = tab.activePane.canDuplicateConnection ? "双击新建相同会话" : "当前状态不响应双击"
            return Entry(id: tab.id, title: title, detail: tab.splitTitleDetail + tab.activePane.connectionDetails + "\n\n\(tab.layout.panes.count) 个终端 · " + action, hasUnreadOutput: tab.hasUnreadOutput, number: numbers[tab.id], connectionStatus: tab.activePane.tabConnectionStatus, sessionFields: tab.activePane.tabSessionFields)
        }, selectedID: selected?.id)
    }
    func update(entries: [Entry], selectedID: UUID?) {
        let shortcuts = ShortcutRuntime.current
        guard displayedEntries != entries || self.selectedID != selectedID || displayedShortcuts != shortcuts else { return }
        let previous = displayedEntries, shortcutsChanged = displayedShortcuts != shortcuts
        let reordered = items.map(\.id) != entries.map(\.id)
        if reordered {
            items.forEach { $0.removeFromSuperview() }
            items = entries.map { entry in
                let item = Item(id: entry.id)
                item.dragEnabled = allowsTabDragging
                item.onDragEnd = { [weak self] in self?.onDragEnd?() }
                // The group strip may be rebuilt while dragging. Keep the weak
                // workspace callback, not a dependency on the old strip's lifetime.
                if let completion = onDragCompletion {
                    item.onDragCompletion = { point, operation, cancelled in completion(entry.id, point, operation, cancelled) }
                }
                item.onSelect = { [weak self] in self?.onSelect?(entry.id) }
                item.onDuplicate = { [weak self] in self?.onDuplicate?(entry.id) }
                item.onClose = { [weak self] in self?.onClose?(entry.id) }
                item.makeMenu = { [weak self] in self?.contextMenu?(entry.id) }
                document.addSubview(item); return item
            }
        }
        self.selectedID = selectedID
        let rebuildMenu = reordered || listButton.menu == nil
        let menu = rebuildMenu ? NSMenu() : listButton.menu!
        if rebuildMenu { menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: "")) }
        for (index, entry) in entries.enumerated() {
            let item = items[index], number = entry.number ?? index + 1
            if !rebuildMenu, !shortcutsChanged, previous?[index] == entry, item.selected == (entry.id == selectedID) { continue }
            let title = entry.number.map { "\($0)  \(entry.title)" } ?? entry.title
            item.selectButton.title = title; item.hasUnreadOutput = entry.hasUnreadOutput
            item.connectionStatus = entry.connectionStatus
            item.selectButton.oshellContentTintColor = entry.hasUnreadOutput ? .systemOrange : .labelColor
            item.selected = entry.id == selectedID
            item.selectButton.font = .systemFont(ofSize: 12, weight: item.selected || entry.hasUnreadOutput ? .semibold : .regular)
            item.selectButton.setAccessibilityLabel("标签 \(number)：\(entry.title)")
            item.selectButton.setAccessibilityValue((item.selected ? "已选中" : "未选中") + (entry.connectionStatus.map { "，" + $0.title } ?? "") + (entry.hasUnreadOutput ? "，有未读输出" : ""))
            item.toolTip = "\(number). \(entry.title)\n" + (entry.connectionStatus.map { "连接状态：" + $0.title + "\n" } ?? "") + (entry.hasUnreadOutput ? "有新输出，切换查看后清除提示\n" : "") + entry.detail
            if let number = entry.number { item.toolTip = (item.toolTip ?? "") + (number <= 9 ? "\n" + ShortcutRuntime.hint(ShortcutAction(rawValue: "tab\(number)")!) + " 跳转" : "\n" + ShortcutRuntime.hint(.tabNumber) + " 输入编号跳转") }
            if onDragCompletion != nil { item.toolTip = (item.toolTip ?? "") + "\n拖到其他窗口的页面或标签栏可合并；拖到窗口外空白处可新建窗口；Esc 取消拖动。" }
            item.sessionFields = entry.sessionFields
            item.hoverDetail = item.toolTip ?? ""
            if entry.sessionFields.isEmpty { item.selectButton.toolTip = item.toolTip }
            else {
                item.toolTip = nil; item.selectButton.toolTip = nil
                item.selectButton.setAccessibilityHelp(item.hoverDetail + "\n悬停后可复制会话字段。")
            }
            item.closeButton.toolTip = "关闭“\(title)”"; item.closeButton.setAccessibilityLabel("关闭“\(title)”")
            item.preferredWidth = min(320, max(120, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]).width + 48))
            let choice = rebuildMenu ? NSMenuItem(title: "", action: #selector(selectFromList(_:)), keyEquivalent: "") : menu.items[index + 1]
            choice.title = (entry.hasUnreadOutput ? "● " : "") + "\(number). \(entry.title)" + (entry.hasUnreadOutput ? "（新输出）" : "")
            choice.representedObject = entry.id; choice.target = self; choice.state = item.selected ? .on : .off
            if rebuildMenu { menu.addItem(choice) }
        }
        let unread = entries.filter(\.hasUnreadOutput).count
        listButton.oshellContentTintColor = unread > 0 ? .systemOrange : nil
        listButton.toolTip = unread > 0 ? "所有标签 · \(unread) 个有未读输出" : "所有标签"
        listButton.setAccessibilityValue(unread > 0 ? "\(unread) 个标签有未读输出" : "无未读输出")
        if rebuildMenu { listButton.menu = menu }
        listButton.isEnabled = !entries.isEmpty
        displayedEntries = entries; displayedShortcuts = shortcuts; needsLayout = true
    }
    override func layout() {
        super.layout()
        let leading = groupButton.isHidden ? 0 : groupWidth + 4
        let contentWidth = items.reduce(CGFloat(5)) { $0 + $1.preferredWidth + 3 }
        let availableWidth = max(0, bounds.width - 60 - leading)
        groupButton.frame = NSRect(x: 2, y: 2, width: groupWidth, height: max(0, bounds.height - 4))
        // Follow the final tab until the strip fills; keep the add button
        // outside the scrolling document so it remains reachable on overflow.
        scroll.frame = NSRect(x: leading, y: 0, width: min(contentWidth, availableWidth), height: bounds.height)
        let buttonHeight = min(24, bounds.height), buttonY = floor((bounds.height - buttonHeight) / 2)
        addButton.frame = NSRect(x: scroll.frame.maxX + 4, y: buttonY, width: 24, height: buttonHeight)
        listButton.frame = NSRect(x: bounds.width - 28, y: buttonY, width: 24, height: buttonHeight)
        document.setFrameSize(NSSize(width: max(scroll.contentSize.width, contentWidth), height: scroll.contentSize.height))
        scroll.tile()
        let height = scroll.contentSize.height
        document.setFrameSize(NSSize(width: max(scroll.contentSize.width, contentWidth), height: height))
        let offset = min(max(0, scroll.contentView.bounds.minX), max(0, contentWidth - scroll.contentSize.width))
        if offset != scroll.contentView.bounds.minX {
            scroll.contentView.scroll(to: NSPoint(x: offset, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        let itemHeight = min(26, max(0, height - 4))
        var x: CGFloat = 4
        for item in items {
            item.frame = NSRect(x: x, y: floor((height - itemHeight) / 2), width: item.preferredWidth, height: itemHeight)
            x += item.preferredWidth + 3
        }
    }
    func clearDragPreview() {
        insertionMarker.removeFromSuperview(); lastDragScroll = 0
    }
    private func draggedTab(_ sender: NSDraggingInfo) -> UUID? {
        guard allowsTabDragging, onReorderTab != nil, sender.draggingSourceOperationMask.contains(.move),
              let source = sender.draggingSource as? Item, source.dragEnabled, let window, let sourceWindow = source.window,
              let raw = sender.draggingPasteboard.string(forType: TabDropHost.pasteboardType),
              let id = UUID(uuidString: raw), source.id == id,
              bounds.contains(convert(sender.draggingLocation, from: nil)) else { return nil }
        if sourceWindow === window { guard canAcceptTab?(id) == true else { return nil } }
        else { guard onExternalTabDrop != nil, canAcceptExternalTab?(id, sourceWindow) == true else { return nil } }
        return id
    }
    /// Convert through the clip view so a scrolled strip uses document coordinates.
    func insertionBefore(at point: NSPoint) -> UUID? {
        layoutSubtreeIfNeeded()
        let location = document.convert(point, from: self)
        return items.first { location.x < $0.frame.midX }?.id
    }
    private func scrollDuringDrag(at point: NSPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastDragScroll == 0 ? 0.03 : min(0.08, max(0, now-lastDragScroll)); lastDragScroll = now
        let direction: CGFloat = point.x < scroll.frame.minX + 24 ? -1 : point.x > scroll.frame.maxX - 24 ? 1 : 0
        let limit = max(0, document.bounds.width-scroll.contentView.bounds.width)
        let offset = min(limit,max(0,scroll.contentView.bounds.minX+direction*CGFloat(elapsed)*360))
        if offset != scroll.contentView.bounds.minX {
            scroll.contentView.scroll(to:NSPoint(x:offset,y:0)); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedTab(sender) != nil else { clearDragPreview(); return [] }
        onDragOver?()
        let point = convert(sender.draggingLocation,from:nil)
        layoutSubtreeIfNeeded(); scrollDuringDrag(at:point)
        let before = insertionBefore(at:point)
        let edge = before.flatMap { id in items.first { $0.id == id }?.frame.minX } ?? items.last?.frame.maxX ?? 4
        let x = convert(NSPoint(x:edge,y:0),from:document).x
        insertionMarker.frame = NSRect(x:min(max(scroll.frame.minX,x-2),max(scroll.frame.minX,scroll.frame.maxX-3)),y:4,width:3,height:max(0,bounds.height-8))
        addSubview(insertionMarker,positioned:.above,relativeTo:nil); insertionMarker.needsDisplay = true
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDragPreview() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggedTab(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDragPreview() }
        guard let id = draggedTab(sender) else { return false }
        let before = insertionBefore(at: convert(sender.draggingLocation, from: nil))
        if let sourceWindow = (sender.draggingSource as? Item)?.window, sourceWindow !== window {
            return onExternalTabDrop?(id, sourceWindow, before) ?? false
        }
        return onReorderTab?(id, before) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearDragPreview() }
    func revealSelection() {
        layoutSubtreeIfNeeded()
        if let item = items.first(where: { $0.id == selectedID }) { document.scrollToVisible(item.frame.insetBy(dx: -4, dy: 0)) }
    }
    var selectedIsVisible: Bool {
        guard let item = items.first(where: { $0.id == selectedID }) else { return items.isEmpty }
        return document.visibleRect.contains(item.frame)
    }
    @objc private func addTab() { onAdd?() }
    @objc private func selectFromList(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onSelect?(id) }
    }
}
