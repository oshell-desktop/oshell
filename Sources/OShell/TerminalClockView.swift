// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// One shared timer for visible window clocks, stopped when the last detaches.
final class TerminalClockTicker {
    static let shared = TerminalClockTicker()
    private let views = NSHashTable<TerminalClockView>.weakObjects()
    private var timer: Timer?
    private let formatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian); value.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return value
    }()
    var isRunning: Bool { timer != nil }
    var subscriberCount: Int { views.allObjects.count }
    func text(at date: Date) -> String {
        // Resolve the Mac's current zone each tick, including changes while open.
        formatter.timeZone = .autoupdatingCurrent
        return formatter.string(from: date)
    }
    private var visibilityObservers = [NSObjectProtocol]()
    func update(_ view: TerminalClockView) {
        views.remove(view)
        if view.needsClockUpdates { views.add(view) }
        refreshVisibility()
    }
    private func refreshVisibility() {
        let subscribers = views.allObjects
        if subscribers.isEmpty {
            timer?.invalidate(); timer = nil
            visibilityObservers.forEach(NotificationCenter.default.removeObserver); visibilityObservers.removeAll()
            return
        }
        if visibilityObservers.isEmpty {
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self, let window = note.object as? NSWindow, self.views.allObjects.contains(where: { $0.window === window }) else { return }
                    self.refreshVisibility()
                })
            }
        }
        let visible = subscribers.filter(\.needsVisibleClockUpdates)
        guard !visible.isEmpty else { timer?.invalidate(); timer = nil; return }
        let text = text(at: Date()); visible.forEach { $0.updateText(text) }
        if timer == nil {
            let now = Date().timeIntervalSince1970
            let source = Timer(fire: Date(timeIntervalSince1970: floor(now) + 1), interval: 1, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }; self.tick()
            }
            source.tolerance = 0.08; timer = source
            RunLoop.main.add(source, forMode: .common); RunLoop.main.add(source, forMode: .modalPanel)
        }
    }
    private func tick() {
        for view in views.allObjects where !view.needsClockUpdates { views.remove(view) }
        refreshVisibility()
    }
    deinit { timer?.invalidate(); visibilityObservers.forEach(NotificationCenter.default.removeObserver) }

}

/// Pure decoration: no PTY writes, no selection, and all pointer events pass through.
final class TerminalClockView: NSView {
    private(set) var enabled = false
    private(set) var position: TerminalClockPosition = .topRight
    private(set) var text = ""
    private(set) var foreground = NSColor.white
    private(set) var clockFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private var disposed = false
    private weak var terminalArea: NSView?
    private var placement = [NSLayoutConstraint]()
    var needsClockUpdates: Bool { enabled && alphaValue > 0 && !disposed && window != nil }
    var needsVisibleClockUpdates: Bool { needsClockUpdates && window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0.5; isHidden = true; wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 1
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); TerminalClockTicker.shared.update(self) }
    override func viewDidHide() { super.viewDidHide(); TerminalClockTicker.shared.update(self) }
    override func viewDidUnhide() { super.viewDidUnhide(); TerminalClockTicker.shared.update(self) }
    func apply(_ preferences: Preferences) {
        guard !disposed else { return }
        var preferences = preferences; preferences.clampClockStyle()
        enabled = preferences.terminalClockEnabled; position = preferences.terminalClockPosition
        let chosen = preferences.terminalClockFontName.isEmpty ? nil : NSFont(name: preferences.terminalClockFontName, size: CGFloat(preferences.terminalClockFontSize))
        clockFont = chosen ?? .monospacedSystemFont(ofSize: CGFloat(preferences.terminalClockFontSize), weight: .medium)
        foreground = NSColor(hex: preferences.terminalClockColor) ?? NSColor(hex: preferences.colorScheme.foreground) ?? .white
        alphaValue = CGFloat(preferences.terminalClockOpacity)
        invalidateIntrinsicContentSize()
        isHidden = !enabled; needsDisplay = true; positionInTerminal()
        TerminalClockTicker.shared.update(self)
    }
    func updateText(_ value: String) {
        guard value != text else { return }
        let old = textRect
        text = value
        invalidateIntrinsicContentSize()
        setNeedsDisplay(old.union(textRect).insetBy(dx: -2, dy: -2))
    }
    private var attributes: [NSAttributedString.Key: Any] { [.font: clockFont, .foregroundColor: foreground] }
    override var intrinsicContentSize: NSSize {
        let size = ((text.isEmpty ? "2000-00-00 00:00:00" : text) as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }
    var textRect: NSRect { bounds }
    func constrain(to terminal: NSView) {
        terminalArea = terminal
        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualTo: terminal.widthAnchor, constant: -24),
            heightAnchor.constraint(lessThanOrEqualTo: terminal.heightAnchor, constant: -24)
        ])
        positionInTerminal()
    }
    private func positionInTerminal() {
        guard let terminalArea else { return }
        NSLayoutConstraint.deactivate(placement)
        let horizontal: NSLayoutConstraint
        switch position.column {
        case 0: horizontal = leadingAnchor.constraint(equalTo: terminalArea.leadingAnchor, constant: 12)
        case 1: horizontal = centerXAnchor.constraint(equalTo: terminalArea.centerXAnchor)
        default: horizontal = trailingAnchor.constraint(equalTo: terminalArea.trailingAnchor, constant: -12)
        }
        let vertical: NSLayoutConstraint
        switch position.row {
        case 0: vertical = topAnchor.constraint(equalTo: terminalArea.topAnchor, constant: 12)
        case 1: vertical = centerYAnchor.constraint(equalTo: terminalArea.centerYAnchor)
        default: vertical = bottomAnchor.constraint(equalTo: terminalArea.bottomAnchor, constant: -12)
        }
        placement = [horizontal, vertical]; NSLayoutConstraint.activate(placement)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard enabled, !text.isEmpty else { return }
        var fitted = attributes
        let natural = intrinsicContentSize
        let scale = min(1, min(bounds.width / max(1, natural.width), bounds.height / max(1, natural.height)))
        if scale < 1 { fitted[.font] = NSFont(descriptor: clockFont.fontDescriptor, size: max(1, clockFont.pointSize * scale)) }
        let size = (text as NSString).size(withAttributes: fitted)
        let rect = NSRect(x: max(0, bounds.width - ceil(size.width)) * CGFloat(position.column) / 2,
                          y: max(0, bounds.height - ceil(size.height)) * CGFloat(position.row) / 2,
                          width: min(bounds.width, ceil(size.width)), height: min(bounds.height, ceil(size.height)))
        (text as NSString).draw(in: rect, withAttributes: fitted)
    }
    func dispose() { disposed = true; enabled = false; isHidden = true; TerminalClockTicker.shared.update(self) }
}

final class TerminalClockSettingsView: NSView, NSComboBoxDelegate {
    let enabled = NSButton(checkboxWithTitle: "显示窗口时钟", target: nil, action: nil)
    let position = NSPopUpButton(), font = NSPopUpButton(), size = NSComboBox()
    let followColor = NSButton(checkboxWithTitle: "跟随终端文字颜色", target: nil, action: nil)
    let color = PopupColorWell()
    let transparency = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    let opacityLabel = NSTextField(labelWithString: "50%")
    let preview = NSView(), previewClock = TerminalClockView()
    private let base: Preferences
    init(_ preferences: Preferences) {
        base = preferences
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 510))
        enabled.state = preferences.terminalClockEnabled ? .on : .off
        enabled.identifier = .init("settings.clock.enabled")
        enabled.toolTip = "显示当前 Mac 的日期和时间，每秒刷新；不会发送到服务器或写入终端记录。"
        for value in TerminalClockPosition.allCases { position.addItem(withTitle: value.title); position.lastItem?.representedObject = value.rawValue }
        position.selectItem(withTitle: preferences.terminalClockPosition.title)
        TerminalFontCatalog.populate(font, selected: preferences.terminalClockFontName)
        size.addItems(withObjectValues: [8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 72, 96])
        size.stringValue = String(format: "%g", preferences.terminalClockFontSize); size.delegate = self
        let formatter = NumberFormatter(); formatter.minimum = 8; formatter.maximum = 96; formatter.maximumFractionDigits = 1
        size.formatter = formatter
        followColor.state = preferences.terminalClockColor.isEmpty ? .on : .off
        color.color = NSColor(hex: preferences.terminalClockColor) ?? NSColor(hex: preferences.colorScheme.foreground) ?? .white
        transparency.doubleValue = (1 - preferences.terminalClockOpacity) * 100; transparency.isContinuous = true
        for (control, id, label) in [(position as NSControl, "position", "时钟位置"), (font, "font", "时钟字体"), (size, "size", "时钟字号"), (color, "color", "时钟颜色"), (transparency, "transparency", "时钟字体透明度")] {
            control.identifier = .init("settings.clock." + id); control.setAccessibilityLabel(label)
            control.target = self; control.action = #selector(changed)
        }
        for button in [enabled, followColor] { button.target = self; button.action = #selector(changed) }
        func row(_ title: String, _ controls: [NSView]) -> NSView {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 88).isActive = true
            let stack = NSStackView(views: [label] + controls); stack.alignment = .centerY; stack.spacing = 12
            stack.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return stack
        }
        position.widthAnchor.constraint(equalToConstant: 130).isActive = true
        font.widthAnchor.constraint(equalToConstant: 360).isActive = true
        size.widthAnchor.constraint(equalToConstant: 100).isActive = true
        color.widthAnchor.constraint(equalToConstant: 64).isActive = true; color.heightAnchor.constraint(equalToConstant: 26).isActive = true
        transparency.widthAnchor.constraint(equalToConstant: 280).isActive = true
        opacityLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let heading = NSTextField(labelWithString: "窗口浮动时钟"); heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "每个 OShell 窗口只显示一个时钟，切换标签或分屏不重复。覆盖在窗口工作区上方，不占用行列，也不拦截点击、选择或滚动。透明度 0% 为不透明，100% 为完全透明。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        preview.wantsLayer = true; preview.layer?.backgroundColor = (NSColor(hex: preferences.colorScheme.background) ?? .black).cgColor
        let sample = NSTextField(wrappingLabelWithString: String(repeating: "INFO  Request completed        INFO  Connection established        INFO  Health check passed\n", count: 8))
        sample.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sample.textColor = NSColor(hex: preferences.colorScheme.foreground)
        sample.translatesAutoresizingMaskIntoConstraints = false; preview.addSubview(sample)
        previewClock.translatesAutoresizingMaskIntoConstraints = false; preview.addSubview(previewClock); previewClock.constrain(to: preview)
        NSLayoutConstraint.activate([sample.topAnchor.constraint(equalTo: preview.topAnchor, constant: 12), sample.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 12), sample.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -12)])
        let stack = NSStackView(views: [heading, enabled, row("显示位置", [position]), row("字体", [font]), row("字号", [size, NSTextField(labelWithString: "8–96 点，可直接输入")]), row("字体颜色", [color, followColor]), row("字体透明度", [transparency, opacityLabel]), hint, preview])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 20), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), hint.widthAnchor.constraint(equalTo: stack.widthAnchor), preview.widthAnchor.constraint(equalTo: stack.widthAnchor), preview.heightAnchor.constraint(equalToConstant: 150)])
        changed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ obj: Notification) { changed() }
    func comboBoxSelectionDidChange(_ notification: Notification) { DispatchQueue.main.async { [weak self] in self?.changed() } }
    @objc func changed() {
        for control in [position as NSControl, font, size, followColor, transparency] { control.isEnabled = enabled.state == .on }
        color.isEnabled = enabled.state == .on && followColor.state == .off
        opacityLabel.stringValue = String(format: "%.0f%%", transparency.doubleValue)
        var draft = base; apply(to: &draft); previewClock.apply(draft)
    }
    func apply(to preferences: inout Preferences) {
        preferences.terminalClockEnabled = enabled.state == .on
        preferences.terminalClockPosition = (position.selectedItem?.representedObject as? String).flatMap(TerminalClockPosition.init(rawValue:)) ?? .topRight
        preferences.terminalClockFontName = font.selectedItem?.representedObject as? String ?? ""
        preferences.terminalClockFontSize = Double(size.stringValue) ?? 12
        preferences.terminalClockColor = followColor.state == .on ? "" : color.color.rgbHex
        preferences.terminalClockOpacity = 1 - transparency.doubleValue / 100
        preferences.clampClockStyle()
    }
    func dispose() { color.deactivate(); previewClock.dispose() }
}
