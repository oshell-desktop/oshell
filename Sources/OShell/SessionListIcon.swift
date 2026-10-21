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
        case .session(.ssh, _): rgb = dark ? (0.40, 0.69, 1.0) : (0.12, 0.40, 0.75)
        case .session(.local, _): rgb = dark ? (0.76, 0.61, 0.97) : (0.51, 0.32, 0.72)
        case .session(.sftp, _): rgb = dark ? (0.39, 0.79, 0.61) : (0.12, 0.51, 0.34)
        case .session(.ftp, _): rgb = dark ? (1.0, 0.66, 0.38) : (0.72, 0.36, 0.10)
        }
        let color = NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
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
            case .session(.ssh, _):
                box(NSRect(x: 2, y: 2, width: 16, height: 16))
                line([(2, 7), (18, 7)])
                line([(5, 14), (8, 12), (5, 10)]); line([(11, 10), (14, 10)])
                for x: CGFloat in [5, 8] { NSBezierPath(ovalIn: NSRect(x: x, y: 3.5, width: 1.8, height: 1.8)).fill() }
            case .session(.local, _):
                box(NSRect(x: 4, y: 6, width: 12, height: 10), radius: 1.5)
                line([(4, 6), (2, 3), (18, 3), (16, 6)])
            case .session(.sftp, _):
                folder()
                let shackle = NSBezierPath(); shackle.lineWidth = 1.4
                shackle.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 2.5, startAngle: 0, endAngle: 180)
                shackle.stroke()
                box(NSRect(x: 6, y: 5, width: 8, height: 5), radius: 1)
                NSBezierPath(ovalIn: NSRect(x: 9.3, y: 6.7, width: 1.4, height: 1.4)).fill()
            case .session(.ftp, _):
                folder()
                line([(6, 11), (14, 11)]); line([(12, 13), (14, 11), (12, 9)])
                line([(14, 7), (6, 7)]); line([(8, 9), (6, 7), (8, 5)])
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
