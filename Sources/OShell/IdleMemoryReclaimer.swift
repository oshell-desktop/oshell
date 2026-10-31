// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import SwiftTerm

/// Large scrollback allocations can be freed while malloc keeps their pages.
/// Coalesce release events; return unused pages off the UI queue once input/output is idle.
final class IdleMemoryReclaimer {
    private var pending: DispatchWorkItem?
    private var reclaiming = false
    private(set) var completedPasses = 0
    private(set) var releasedBytes = 0
    private(set) var lastDurationMilliseconds = 0.0

    func cancel() { pending?.cancel(); pending = nil }

    func schedule(isIdle: @escaping () -> Bool, clearSharedCaches: @escaping () -> Bool = { true }) {
        cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            guard isIdle(), !self.reclaiming else {
                self.schedule(isIdle: isIdle, clearSharedCaches: clearSharedCaches); return
            }
            self.reclaiming = true
            // Drain Objective-C cache entries before asking malloc to return pages.
            autoreleasepool { if clearSharedCaches() { TerminalView.releaseSharedRenderCaches() } }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let started = DispatchTime.now().uptimeNanoseconds
                let bytes = malloc_zone_pressure_relief(nil, 0)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.reclaiming = false
                    self.completedPasses += 1; self.releasedBytes += bytes
                    self.lastDurationMilliseconds = elapsed
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    deinit { cancel() }
}
