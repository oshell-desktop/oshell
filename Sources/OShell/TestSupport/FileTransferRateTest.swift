// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum FileTransferRateTest {
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.global(qos:.userInitiated).async {
            var checks = [String:Bool]()
            let data = Data(repeating:0x41,count:65536)
            do {
                checks.merge(try FileProcessChecks.run()) { _, new in new }
                let sliced = data.dropFirst(7)
                var copied = Data()
                try FileTransferRateLimiter().paced(sliced) { copied.append($0) }
                checks["slicedDataPreservesBytes"] = copied == sliced
                let limiter = FileTransferRateLimiter(); limiter.setLimit(65536)
                let start = ProcessInfo.processInfo.systemUptime; var count = 0
                try limiter.paced(data) { count += $0.count }
                checks["fixedLimitPacesPayload"] = count == data.count && ProcessInfo.processInfo.systemUptime-start >= 0.75
                let lifted = FileTransferRateLimiter(); lifted.setLimit(1024)
                DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { lifted.setLimit(0) }
                let liftStart = ProcessInfo.processInfo.systemUptime
                try lifted.paced(data) { _ in }
                checks["unlimitedWakesWaitingTransfer"] = ProcessInfo.processInfo.systemUptime-liftStart < 1.5
                let raised = FileTransferRateLimiter(); raised.setLimit(1024)
                DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { raised.setLimit(1024*1024) }
                let raiseStart = ProcessInfo.processInfo.systemUptime
                try raised.paced(data) { _ in }
                checks["higherLimitAppliesWhileWaiting"] = ProcessInfo.processInfo.systemUptime-raiseStart < 1.5
                let lowered = FileTransferRateLimiter(); var sent = 0
                let lowerStart = ProcessInfo.processInfo.systemUptime
                try lowered.paced(Data(repeating:1,count:98304)) { chunk in
                    sent += chunk.count; if sent == 32768 { lowered.setLimit(65536) }
                }
                checks["lowerLimitAppliesMidTransfer"] = sent == 98304 && ProcessInfo.processInfo.systemUptime-lowerStart >= 0.75
                let cancelled = FileTransferRateLimiter(); cancelled.setLimit(1024)
                DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { cancelled.cancel() }
                let cancelStart = ProcessInfo.processInfo.systemUptime
                do { try cancelled.paced(data) { _ in }; checks["cancellationInterruptsWait"] = false }
                catch { checks["cancellationInterruptsWait"] = ProcessInfo.processInfo.systemUptime-cancelStart < 1.5 }
                let smallReads = FileTransferRateLimiter(); smallReads.setLimit(1024)
                checks["lowRateBoundsReadAhead"] = smallReads.readChunkSize == 1024
                smallReads.setLimit(0); checks["unlimitedRestoresReadSize"] = smallReads.readChunkSize == 32768
                checks["independentSessions"] = FileTransferRateLimiter().bytesPerSecond == 0 && limiter.bytesPerSecond == 65536
                checks["SCPUsesKbits"] = FileTransferRateLimiter.scpArguments(1048576) == ["-l","8192"] && FileTransferRateLimiter.scpArguments(0).isEmpty
                checks["customMiB"] = RemoteFileSession.parseTransferRate("1.5",unit:1048576) == 1572864
                checks["customKiB"] = RemoteFileSession.parseTransferRate("128",unit:1024) == 131072
                checks["zeroUnlimited"] = RemoteFileSession.parseTransferRate("0",unit:1024) == 0
                checks["invalidRatesRejected"] = ["-1","nan","inf","abc","0.5","1048577"].allSatisfy { RemoteFileSession.parseTransferRate($0,unit:1024) == nil }
            } catch { checks["unexpectedFailure"] = false }
            let result = checks
            DispatchQueue.main.async {
                let report:[String:Any] = ["passed":result.values.allSatisfy { $0 },"checks":result]
                if let path = ProcessInfo.processInfo.environment["OSHELL_FILE_RATE_OUTPUT"] { try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path)) }
                workspace.shutdown(); NSApp.terminate(nil)
            }
        }
    }
}
