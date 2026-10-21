// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Presentation only: session types and shared configuration stay unchanged.
enum SessionListIcon: Hashable {
    case parent, directory, session(SessionKind, shortcut: Bool)

    var label: String {
        switch self {
        case .parent: return "上一级目录"
        case .directory: return "目录"
        case .session(let kind, let shortcut):
            let title: String
            switch kind {
            case .ssh: title = "SSH · 远程终端"
            case .local: title = "本地终端"
            case .sftp: title = "SFTP · 安全文件传输"
            case .ftp: title = "FTP · 文件传输"
            }
            return shortcut ? "Link · 快捷引用 · " + title : title
        }
    }

    private var badgeText: String? {
        switch self {
        case .session(.ssh, false): return "SSH"
        case .session(.sftp, false): return "SFTP"
        case .session(.ftp, false): return "FTP"
        default: return nil
        }
    }

    private struct Key: Hashable { let style: SessionListIcon; let dark: Bool }
    // At most 20 images, independent of the number of profiles or reused rows.
    private static var images = [Key: NSImage]()
    func image(dark: Bool) -> NSImage {
        let key = Key(style: self, dark: dark)
        if let image = Self.images[key] { return image }
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch self {
        case .parent: rgb = dark ? (0.70, 0.72, 0.76) : (0.40, 0.42, 0.46)
        case .directory: rgb = dark ? (0.91, 0.73, 0.36) : (0.61, 0.43, 0.12)
        case .session(_, true): rgb = dark ? (0.36, 0.81, 0.88) : (0.02, 0.49, 0.57)
        case .session(.ssh, _): rgb = dark ? (0.5137, 0.7216, 1.0) : (0.1451, 0.4118, 0.7294)
        case .session(.local, _): rgb = dark ? (0.76, 0.61, 0.97) : (0.51, 0.32, 0.72)
        case .session(.sftp, _): rgb = dark ? (0.4471, 0.8275, 0.6353) : (0.1294, 0.4627, 0.2941)
        case .session(.ftp, _): rgb = dark ? (1.0, 0.7294, 0.4784) : (0.6392, 0.3333, 0.0784)
        }
        let color = NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        let image = NSImage(size: NSSize(width: badgeText == nil ? 20 : 36, height: 20), flipped: false) { _ in
            color.setStroke(); color.setFill()
            func line(_ points: [(CGFloat, CGFloat)]) {
                let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.move(to: NSPoint(x: points[0].0, y: points[0].1))
                for (x, y) in points.dropFirst() { path.line(to: NSPoint(x: x, y: y)) }; path.stroke()
            }
            func box(_ rect: NSRect, radius: CGFloat = 2) {
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                color.withAlphaComponent(0.10).setFill(); path.fill(); color.setFill()
                path.lineWidth = 1.5; path.stroke()
            }
            func folder() {
                let path = NSBezierPath(); path.lineWidth = 1.4; path.lineJoinStyle = .round
                path.move(to: NSPoint(x: 2, y: 3))
                for (x, y): (CGFloat, CGFloat) in [(2, 17), (8, 17), (10, 15), (18, 15), (18, 3)] {
                    path.line(to: NSPoint(x: x, y: y))
                }
                path.close(); color.withAlphaComponent(0.10).setFill(); path.fill(); color.setFill(); path.stroke()
            }
            switch self {
            case .parent:
                line([(16, 5), (16, 11), (4, 11)]); line([(8, 15), (4, 11), (8, 7)])
            case .directory:
                folder()
            case .session(_, true):
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: 10, yBy: 10); transform.rotate(byDegrees: 45)
                transform.translateX(by: -10, yBy: -10); transform.concat()
                let chain = NSBezierPath(); chain.lineWidth = 1.7; chain.lineCapStyle = .round
                chain.move(to: NSPoint(x: 9, y: 13)); chain.line(to: NSPoint(x: 5, y: 13))
                chain.appendArc(withCenter: NSPoint(x: 5, y: 10), radius: 3, startAngle: 90, endAngle: 270)
                chain.line(to: NSPoint(x: 9, y: 7))
                chain.move(to: NSPoint(x: 11, y: 7)); chain.line(to: NSPoint(x: 15, y: 7))
                chain.appendArc(withCenter: NSPoint(x: 15, y: 10), radius: 3, startAngle: 270, endAngle: 90)
                chain.line(to: NSPoint(x: 11, y: 13)); chain.stroke()
                line([(7, 10), (13, 10)])
                NSGraphicsContext.restoreGraphicsState()
            case .session(.ssh, false), .session(.sftp, false), .session(.ftp, false):
                color.withAlphaComponent(dark ? 0.18 : 0.09).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 36, height: 20), xRadius: 5, yRadius: 5).fill()
                color.withAlphaComponent(dark ? 0.35 : 0.23).setStroke()
                let border = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 35, height: 19), xRadius: 4.5, yRadius: 4.5)
                border.lineWidth = 1; border.stroke()
                let text = NSAttributedString(string: self.badgeText!, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: color])
                let size = text.size()
                text.draw(at: NSPoint(x: (36 - size.width) / 2, y: (20 - size.height) / 2))
            case .session(.local, _):
                box(NSRect(x: 4, y: 6, width: 12, height: 10), radius: 1.5)
                line([(4, 6), (2, 3), (18, 3), (16, 6)])
            }
            return true
        }
        image.accessibilityDescription = label
        Self.images[key] = image
        return image
    }
}

final class SessionListIconView: NSImageView {
    var style: SessionListIcon? { didSet { refresh() } }
    private func refresh() {
        let dark: Bool
        if #available(macOS 10.14, *) { dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        else { dark = false }
        image = style?.image(dark: dark)
        setAccessibilityLabel(style?.label)
    }
    @available(macOS 10.14, *)
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
}
