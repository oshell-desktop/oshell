// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

// Approved OShell brand: graphite + flame-orange O-shaped multi-session terminal.
// Generate the iconset for both supported architectures from this single source.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func color(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func stroke(_ points: [NSPoint], width: CGFloat, tint: NSColor) {
    let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; tint.setStroke(); path.stroke()
}
func renderIcon(_ pixels: Int) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let scale = NSAffineTransform(); scale.scale(by: CGFloat(pixels) / 1024); scale.concat()
    let tile = rounded(104, 104, 816, 816, 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0x121A26, alpha: 0.22)
    shadow.shadowBlurRadius = 24 * CGFloat(pixels) / 1024; shadow.shadowOffset = NSSize(width: 0, height: -14 * CGFloat(pixels) / 1024); shadow.set()
    color(0x20252D).setFill(); tile.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x343C47), ending: color(0x151B23))!.draw(in: tile, angle: -75)
    if pixels >= 64 { color(0xFFFFFF, alpha: 0.14).setStroke(); tile.lineWidth = 3; tile.stroke() }
    // Two offset sessions behind the active terminal. The O remains the hero.
    for (x, y, tint) in [(CGFloat(296), CGFloat(290), UInt32(0x556171)), (258, 252, UInt32(0x8894A4))] {
        let frame = rounded(x, y, 530, 548, 180)
        color(tint).setFill(); frame.fill()
        color(0x242C36).setFill(); rounded(x + 25, y + 25, 480, 498, 155).fill()
    }
    let shell = rounded(212, 194, 560, 588, 192)
    NSGradient(starting: color(0xFF9B56), ending: color(0xF14A3D))!.draw(in: shell, angle: -75)
    let screen = rounded(273, 255, 438, 466, 132)
    NSGradient(starting: color(0x252D39), ending: color(0x101720))!.draw(in: screen, angle: -90)
    // Active tab inset. Retain simple main silhouette at small icon sizes.
    color(0xFF8550).setFill(); rounded(335, 677, 112, 13, 6.5).fill()
    color(0x788492, alpha: 0.7).setFill(); rounded(465, 677, 70, 13, 6.5).fill(); rounded(553, 677, 70, 13, 6.5).fill()
    stroke([NSPoint(x: 352, y: 588), NSPoint(x: 448, y: 498), NSPoint(x: 352, y: 408)], width: 48, tint: color(0xF7F8FA))
    stroke([NSPoint(x: 514, y: 409), NSPoint(x: 622, y: 409)], width: 48, tint: color(0xFF8550))
    NSGraphicsContext.restoreGraphicsState(); return image
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let bitmap = renderIcon(points * scale)
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
// Optional README asset, generated from exactly the same drawing as the app.
if CommandLine.arguments.count > 2 {
    let brand = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
    try renderIcon(1024).representation(using: .png, properties: [:])!.write(to: brand.appendingPathComponent("OShell-icon.png"))
}
