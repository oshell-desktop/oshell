// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

struct AIStopGesture {
    private var lastEscape: TimeInterval?
    mutating func reset() { lastEscape = nil }
    mutating func consume(_ bytes: [UInt8], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if bytes == [3] { reset(); return true }
        guard bytes == [27] else { reset(); return false }
        if let previous = lastEscape, now >= previous, now - previous <= 0.5 { reset(); return true }
        lastEscape = now; return false
    }
}
