// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

// OShell brand: a single graphite terminal with a flame-orange rounded frame.
// Generate the iconset for both supported architectures from this single source.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func color(_ value: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
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
    let shell = rounded(104, 104, 816, 816, 204)
    NSGradient(starting: color(0xFF9B56), ending: color(0xFF6B45))!.draw(in: shell, angle: -90)
    let screen = rounded(172, 172, 680, 680, 136)
    NSGradient(starting: color(0x343C47), ending: color(0x20252D))!.draw(in: screen, angle: -90)
    color(0xFF8550).setFill(); rounded(274, 699, 153, 34, 17).fill()
    color(0x788492).setFill(); rounded(461, 699, 119, 34, 17).fill(); rounded(631, 699, 102, 34, 17).fill()
    stroke([NSPoint(x: 291, y: 580), NSPoint(x: 444, y: 444), NSPoint(x: 291, y: 308)], width: 76, tint: color(0xF7F8FA))
    stroke([NSPoint(x: 546, y: 308), NSPoint(x: 716, y: 308)], width: 76, tint: color(0xFF8550))
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
