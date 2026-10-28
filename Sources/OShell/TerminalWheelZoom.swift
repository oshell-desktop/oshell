// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Accumulate deliberate wheel movement, without zooming on trackpad momentum.
struct TerminalWheelZoom {
    private var accumulated: CGFloat = 0
    private var lastTimestamp: TimeInterval?
    private var precise: Bool?

    mutating func reset() { self = Self() }

    mutating func step(for event: NSEvent) -> Int? {
        guard event.momentumPhase.isEmpty, !event.phase.contains(.cancelled) else { reset(); return nil }
        if event.phase.contains(.began) || precise != event.hasPreciseScrollingDeltas
            || lastTimestamp.map({ event.timestamp - $0 > 0.8 || event.timestamp < $0 }) == true {
            reset()
        }
        precise = event.hasPreciseScrollingDeltas; lastTimestamp = event.timestamp
        // Up on the physical wheel enlarges text, regardless of natural scrolling.
        let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        if delta * accumulated < 0 { accumulated = 0 }
        accumulated += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 120 : 12
        let step = abs(accumulated) >= threshold ? (accumulated > 0 ? 1 : -1) : nil
        if step != nil { accumulated = accumulated.truncatingRemainder(dividingBy: threshold) }
        if event.phase.contains(.ended) { reset() }
        return step
    }
}
