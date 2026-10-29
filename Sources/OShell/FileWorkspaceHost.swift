// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class FileManagerSurface: InterfaceSurfaceView {
    var minimumHeight: CGFloat = 360
    override var isFlipped: Bool { true }
}

/// Reparents the existing file UI; never creates a backend or sends terminal input.
final class FileWorkspaceHost: NSView {
    private final class Divider: NSView {
        var vertical = true
        var resize: ((NSPoint) -> Void)?
        override func draw(_ dirtyRect: NSRect) { NSColor.separatorColor.setFill(); NSBezierPath(rect: bounds).fill() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown) }
        override func mouseDown(with event: NSEvent) {
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }; resize?(next.locationInWindow)
            }
        }
    }
    private final class Viewport: NSScrollView {
        override func layout() {
            super.layout()
            documentView?.setFrameSize(NSSize(width: contentSize.width, height: max((documentView as? FileManagerSurface)?.minimumHeight ?? 360, contentSize.height)))
        }
    }
    private let terminal: NSView, panel = FileManagerSurface(), viewport = Viewport(), divider = Divider()
    private weak var manager: RemoteFileWindow?
    private var placement: FileManagementSettings.Placement = .right
    private var sideWidth: CGFloat = 420, bottomHeight: CGFloat = 340
    private(set) var showing = false
    var onHide: (() -> Void)?
    init(terminal: NSView) {
        self.terminal = terminal; super.init(frame: .zero)
        for view in [terminal, panel, divider] { addSubview(view) }
        let title = AppUI.label("文件管理", size: 12, weight: .semibold)
        let popout = AppUI.button("独立窗口", symbol: "arrow.up.right.square") { [weak self] in self?.manager?.present(.window) }
        popout.toolTip = "本次在独立窗口显示，不改变默认位置"
        let hide = AppUI.button("", symbol: "xmark") { [weak self] in self?.hidePanel() }
        hide.setAccessibilityLabel("隐藏文件管理，保留连接和传输"); hide.toolTip = "隐藏面板，传输继续"
        let header = AppUI.row([title, NSView(), popout, hide]); header.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(header)
        viewport.drawsBackground = false; viewport.hasVerticalScroller = true; viewport.autohidesScrollers = true; viewport.scrollerStyle = .overlay
        viewport.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(viewport)
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4), header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8), header.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8), header.heightAnchor.constraint(equalToConstant: 28), viewport.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4), viewport.leadingAnchor.constraint(equalTo: panel.leadingAnchor), viewport.trailingAnchor.constraint(equalTo: panel.trailingAnchor), viewport.bottomAnchor.constraint(equalTo: panel.bottomAnchor)])
        divider.resize = { [weak self] point in
            guard let self else { return }; let point = self.convert(point, from: nil)
            switch self.placement {
            case .left: self.sideWidth = point.x
            case .right: self.sideWidth = self.bounds.width - point.x
            case .bottom: self.bottomHeight = point.y
            case .window: break
            }; self.needsLayout = true
        }
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func attach(_ manager: RemoteFileWindow, content: NSView, placement: FileManagementSettings.Placement) {
        if let previous = self.manager, previous !== manager { previous.parkDockedContent() }
        self.manager = manager; self.placement = placement
        if viewport.documentView !== content { content.removeFromSuperview(); viewport.documentView = content }
        showing = true; needsLayout = true; layoutSubtreeIfNeeded()
    }
    func detach(_ manager: RemoteFileWindow) {
        guard self.manager === manager else { return }
        viewport.documentView = nil; self.manager = nil; showing = false; needsLayout = true
    }
    func isPresenting(_ manager: RemoteFileWindow) -> Bool { showing && self.manager === manager }
    func hidePanel() { onHide?(); showing = false; needsLayout = true }
    @discardableResult func hideIfFocused() -> Bool {
        guard showing else { return false }
        var focused = window?.firstResponder as? NSView
        if let editor = focused as? NSTextView, editor.isFieldEditor { focused = (editor.delegate as? NSView) ?? editor }
        guard focused?.isDescendant(of: panel) == true else { return false }
        hidePanel(); return true
    }
    override func layout() {
        super.layout(); panel.isHidden = !showing; divider.isHidden = !showing
        guard showing else { terminal.frame = bounds; return }
        divider.vertical = placement != .bottom
        if placement == .bottom {
            let height = min(max(220, bottomHeight), bounds.height * 0.6)
            panel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
            divider.frame = NSRect(x: 0, y: height, width: bounds.width, height: 5)
            terminal.frame = NSRect(x: 0, y: height + 5, width: bounds.width, height: max(0, bounds.height - height - 5))
        } else {
            let width = min(max(300, sideWidth), bounds.width * 0.48)
            let left = placement == .left
            panel.frame = NSRect(x: left ? 0 : bounds.width - width, y: 0, width: width, height: bounds.height)
            divider.frame = NSRect(x: left ? width : bounds.width - width - 5, y: 0, width: 5, height: bounds.height)
            terminal.frame = NSRect(x: left ? width + 5 : 0, y: 0, width: max(0, bounds.width - width - 5), height: bounds.height)
        }
        window?.invalidateCursorRects(for: divider)
    }
}

extension WorkspaceController {
    func wrapWithFileManager(_ terminal: NSView) -> NSView {
        let host = FileWorkspaceHost(terminal: terminal); fileHost = host
        host.onHide = { [weak self] in self?.selectedTab?.activePane.activate() }
        return host
    }
}

/// Overflow stays within each file toolbar rather than forcing the workspace wide.
final class FileControlStrip: NSScrollView {
    private let row: NSStackView
    init(_ row: NSStackView) {
        self.row = row; super.init(frame: .zero)
        drawsBackground = false; hasHorizontalScroller = true; hasVerticalScroller = false
        autohidesScrollers = true; scrollerStyle = .overlay
        row.translatesAutoresizingMaskIntoConstraints = true; documentView = row
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); row.layoutSubtreeIfNeeded()
        row.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, row.fittingSize.width), height: contentSize.height)
    }
}
