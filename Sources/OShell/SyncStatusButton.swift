// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import QuartzCore

final class SyncStatusButton: NSButton {
    private let track = CAShapeLayer(), ring = CAShapeLayer()
    private var completionUntil: CFTimeInterval = 0
    private var observers = [NSObjectProtocol]()
    private var motionObserver: NSObjectProtocol?
    var presentation = SyncStatusPresentation(sync: nil) {
        didSet {
            if image == nil || oldValue.mark != presentation.mark {
                completionUntil = presentation.mark == .complete ? CACurrentMediaTime() + 2 : 0
                ring.removeAllAnimations(); updateImage()
            }
            updateRing()
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.name = "sync.progress.track"; ring.name = "sync.progress.ring"
        for shape in [track, ring] {
            shape.fillColor = nil; shape.lineWidth = 1.5; shape.lineCap = .round
            shape.zPosition = 1; layer?.addSublayer(shape)
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.window else { return }
                self.updateRing()
            })
        }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateRing() }
        updateImage(); updateRing()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }
    private func updateImage() {
        let symbol = presentation.image
        // Reserve a stable outer gutter for the ring without changing toolbar width.
        image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 4, y: 4, width: 14, height: 14)); return true
        }
    }
    override func layout() { super.layout(); updateRing() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateRing() }
    override func viewDidHide() { super.viewDidHide(); updateRing() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateRing() }
    @available(macOS 10.14, *)
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); updateImage(); updateRing()
    }
    private func updateRing() {
        let visible = window?.isVisible == true && window?.isMiniaturized != true && !isHiddenOrHasHiddenAncestor
        let working = presentation.mark == .working
        let completed = presentation.mark == .complete && CACurrentMediaTime() < completionUntil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let imageRect = cell?.imageRect(forBounds: bounds) ?? bounds
        let size = max(0, min(22, min(bounds.width, bounds.height) - 2))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let appearance = NSAppearance.current; NSAppearance.current = effectiveAppearance
        let color = presentation.color.cgColor; NSAppearance.current = appearance
        for shape in [track, ring] {
            shape.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            shape.position = CGPoint(x: imageRect.midX, y: imageRect.midY)
            shape.path = CGPath(ellipseIn: shape.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            shape.strokeColor = color
            shape.isHidden = !visible || !(working || completed)
        }
        track.opacity = working ? 0.18 : 0
        ring.strokeEnd = working ? 0.28 : 1
        ring.opacity = working ? 1 : 0
        CATransaction.commit()
        if !visible || !(working || completed) { ring.removeAllAnimations(); return }
        if working {
            ring.removeAnimation(forKey: "sync.complete")
            if reduceMotion { ring.removeAnimation(forKey: "sync.rotation") }
            else if ring.animation(forKey: "sync.rotation") == nil {
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotation.fromValue = 0; rotation.toValue = -2 * Double.pi
                rotation.duration = 1.1; rotation.repeatCount = .infinity
                rotation.beginTime = CACurrentMediaTime()
                ring.add(rotation, forKey: "sync.rotation")
            }
        } else {
            ring.removeAnimation(forKey: "sync.rotation")
            if ring.animation(forKey: "sync.complete") == nil {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1; fade.toValue = 0
                fade.beginTime = completionUntil; fade.duration = reduceMotion ? 0.01 : 0.25
                fade.fillMode = .backwards
                ring.add(fade, forKey: "sync.complete")
            }
        }
    }
}
