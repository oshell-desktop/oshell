#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Exercise the actual idle reclaimer with real malloc and SwiftTerm, without a window."""
import argparse
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--products', type=pathlib.Path, default=root/'work/build-tests/swift/out/Products/Release')
args = parser.parse_args()
products = args.products.resolve()
if not (products/'SwiftTerm.o').exists():
    parser.error('Build the test app first: bash scripts/build.sh --tests')
fixture = r'''
import Foundation
import Darwin
@main struct Checks {
    static func main() throws {
        var checks = [String: Bool]()
        func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        let reclaimer = IdleMemoryReclaimer()
        var idle = false, cacheDecisions = 0, heartbeat = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in heartbeat += 1 }
        for _ in 0..<50 {
            reclaimer.schedule(isIdle: { idle }, clearSharedCaches: { cacheDecisions += 1; return false })
        }
        pump(2.3)
        checks["busyWorkDefersReclamation"] = reclaimer.completedPasses == 0 && cacheDecisions == 0
        idle = true; pump(2.5)
        checks["settledBurstReclaimsOnce"] = reclaimer.completedPasses == 1 && cacheDecisions == 1
        checks["mainRunLoopRemainsResponsive"] = heartbeat > 100
        pump(2.3)
        checks["noPeriodicReclaimWhenIdle"] = reclaimer.completedPasses == 1
        reclaimer.schedule(isIdle: { true }); reclaimer.cancel(); pump(2.3)
        checks["cancelPreventsPendingPass"] = reclaimer.completedPasses == 1
        weak var released: IdleMemoryReclaimer?
        autoreleasepool {
            let temporary = IdleMemoryReclaimer(); released = temporary
            temporary.schedule(isIdle: { true })
        }
        checks["pendingWorkDoesNotRetainOwner"] = released == nil
        reclaimer.schedule(isIdle: { true }); pump(2.3)
        checks["realSharedCacheReleaseCompletes"] = reclaimer.completedPasses == 2
        timer.invalidate()
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks,
            "reclaimPasses": reclaimer.completedPasses, "lastReclaimMilliseconds": reclaimer.lastDurationMilliseconds,
            "releasedBytes": reclaimer.releasedBytes]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        if checks.values.contains(false) { exit(1) }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='oshell-idle-reclaimer-') as folder:
    folder = pathlib.Path(folder)
    swift = folder/'Checks.swift'
    binary = folder/'check'
    swift.write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', '-O', '-I', str(products),
        str(root/'Sources/OShell/IdleMemoryReclaimer.swift'), str(swift),
        str(products/'SwiftTerm.o'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
