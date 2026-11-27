// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// Presentation only: never serialize a profile or decrypt credentials for a
/// tooltip or clipboard entry.
enum QuickConnectDetails {
    static func connection(_ profile: SessionProfile, configuration: Configuration,
                           globalProxy: Result<GlobalProxySettings, Error>) -> String {
        var lines = ["协议：\(profile.kind.title)"]
        if profile.kind == .local { lines.append("连接方式：本地 Shell") }
        else {
            lines += ["主机：\(profile.host)", "端口：\(profile.port)",
                      "用户名：\(profile.username.isEmpty ? "未指定" : profile.username)"]
        }
        if profile.kind.usesSSH {
            do {
                let global = try globalProxy.get()
                let resolved = try global.resolve(profile, configuration: configuration)
                var hops = resolved.runtimeProxyRoute
                if hops.isEmpty, resolved.proxy.kind != .none { hops = [resolved.proxy] }
                if !hops.isEmpty {
                    let route = hops.map { hop in
                        let host = hop.host.contains(":") && !hop.host.hasPrefix("[") ? "[\(hop.host)]" : hop.host
                        let user = hop.username.isEmpty ? "" : hop.username + "@"
                        return "\(hop.kind.title) · \(user)\(host):\(hop.port)"
                    }.joined(separator: " → ")
                    lines.append("代理链：\(route)")
                } else if !resolved.jumpHost.isEmpty { lines.append("跳板机：\(resolved.jumpHost)") }
                else { lines.append("代理：直连") }
                if global.enabled { lines.append("全局代理：已计入连接路线") }
            } catch { lines.append("代理：配置不可用，请检查代理设置") }
            lines.append("保持连接：" + (profile.keepAlive.enabled ? "每 \(profile.keepAlive.interval) 秒" : "关闭"))
            if !profile.tunnels.isEmpty { lines.append("端口转发：\(profile.tunnels.count) 条") }
        }
        if !profile.initialDirectory.isEmpty, profile.initialDirectory != "." {
            lines.append("初始目录：\(profile.initialDirectory)")
        }
        return lines.joined(separator: "\n")
    }
    static func text(profile: SessionProfile, title: String, directory: String, shortcut: Bool, connection: String) -> String {
        var lines = ["会话：\(title)", "目录：\(SessionDirectory.display(directory))"]
        if shortcut {
            lines += ["类型：快捷引用", "源会话：\(profile.name)", "源目录：\(SessionDirectory.display(profile.group))"]
        }
        lines.append(connection)
        return lines.joined(separator: "\n")
    }
}

/// Retain the NSMenuItem action/title for native keyboard navigation; the
/// separate copy target never invokes the connect action.
final class QuickConnectMenuRow: NSView {
    private final class ConnectButton: NSButton {
        override func draw(_ dirtyRect: NSRect) {
            let highlighted = enclosingMenuItem?.isHighlighted == true
            if let image {
                image.draw(in: NSRect(x: 10 + (44 - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                                     width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let font = NSFont.menuFont(ofSize: 0)
            let height = (title as NSString).size(withAttributes: [.font: font]).height
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in: NSRect(x: 62, y: (bounds.height - height) / 2, width: max(0, bounds.width - 68), height: height),
                withAttributes: [.font: font, .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : .labelColor,
                                 .paragraphStyle: paragraph])
        }
    }
    private let connectButton = ConnectButton()
    let copyButton = NSButton()
    let details: String
    var canCopy: (() -> Bool)?
    var pasteboard = NSPasteboard.general
    private static let copyImage = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)

    init(title: String, image: NSImage, details: String) {
        self.details = details
        let width = min(480, max(240, (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width + 110))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        autoresizingMask = [.width]; toolTip = details
        connectButton.title = title; connectButton.image = image; connectButton.isBordered = false
        connectButton.toolTip = details; connectButton.setAccessibilityLabel("连接：" + title)
        connectButton.setAccessibilityHelp(details)
        connectButton.target = self; connectButton.action = #selector(connect)
        copyButton.image = Self.copyImage; copyButton.imagePosition = .imageOnly
        copyButton.bezelStyle = .recessed; copyButton.showsBorderOnlyWhileMouseInside = true
        copyButton.toolTip = "复制连接信息"; copyButton.setAccessibilityLabel("复制连接信息：" + title)
        copyButton.identifier = .init("quickConnect.copy")
        copyButton.target = self; copyButton.action = #selector(copyDetails)
        addSubview(connectButton); addSubview(copyButton); layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        connectButton.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 36), height: bounds.height)
        copyButton.frame = NSRect(x: bounds.maxX - 34, y: (bounds.height - 28) / 2, width: 28, height: 28)
    }
    override func draw(_ dirtyRect: NSRect) {
        if enclosingMenuItem?.isHighlighted == true { NSColor.selectedMenuItemColor.setFill(); bounds.fill() }
    }
    override func viewWillDraw() {
        let color: NSColor = enclosingMenuItem?.isHighlighted == true ? .selectedMenuItemTextColor : .secondaryLabelColor
        if copyButton.contentTintColor != color { copyButton.contentTintColor = color }
        connectButton.needsDisplay = true
        super.viewWillDraw()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        copyButton.image = Self.copyImage; copyButton.toolTip = "复制连接信息"
    }
    @objc private func connect() {
        guard let item = enclosingMenuItem, item.isEnabled, let action = item.action else { return }
        var menu = item.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTrackingWithoutAnimation()
        _ = NSApp.sendAction(action, to: item.target, from: item)
    }
    @objc func copyDetails() {
        guard canCopy?() == true else { return }
        pasteboard.clearContents()
        guard pasteboard.setString(details, forType: .string) else { return }
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        copyButton.toolTip = "已复制连接信息"
    }
}
