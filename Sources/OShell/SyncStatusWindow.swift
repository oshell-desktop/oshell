// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// A modeless monitor: it must not block sync's modal-editor safety checks.
final class SyncStatusWindow: NSWindowController {
    private let configure: () -> Void
    init(sync: WebDAVSync, configure: @escaping () -> Void) {
        self.configure = configure
        let window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.attachesToOwner = false
        window.title = "配置同步"; window.identifier = .init("sync.status.window")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let card = SyncStatusView(sync: sync, immediate: true)
        card.onUnlock = { [weak self] in self?.configure() }
        let settings = NSButton(title: "同步配置…", target: self, action: #selector(openConfiguration))
        settings.bezelStyle = .rounded; settings.identifier = .init("sync.status.configure")
        let root = window.contentView!
        let stack = NSStackView(views: [card, settings])
        stack.orientation = .vertical; stack.alignment = .trailing; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        card.onLayoutChange = { [weak window, weak stack] in
            guard let window, let stack else { return }
            stack.layoutSubtreeIfNeeded()
            let height = max(320, stack.fittingSize.height + 32)
            if abs((window.contentView?.bounds.height ?? 0) - height) > 1 {
                window.setContentSize(NSSize(width: 760, height: height))
            }
        }
        card.refresh(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openConfiguration() { configure() }
}
