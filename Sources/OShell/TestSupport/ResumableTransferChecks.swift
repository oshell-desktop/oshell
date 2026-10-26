// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

enum ResumableTransferChecks {
    static func run(profile: SessionProfile, known: URL, root: URL, checks: inout [String: Bool]) throws {
        let local = root.appendingPathComponent("local"), remote = root.appendingPathComponent("remote")
        let payload = Data((0..<196608).map { UInt8($0 % 251) })
        let source = local.appendingPathComponent("resume-source.bin"); try payload.write(to: source)
        func backend() throws -> SFTPBackend { let b = try SFTPBackend(profile:profile,knownHosts:known); try b.connect(); return b }
        func interrupted(_ job: ResumableFileTransfer, atEnd: Bool = false) throws -> Bool {
            let b = try backend(); defer { b.cancel() }; var cancelled = false
            do {
                try b.transfer(job) { bytes,total in
                    if !cancelled && bytes > 0 && (atEnd ? bytes == total : bytes >= 32768) { cancelled = true; b.cancel() }
                }; return false
            } catch { return cancelled && job.ownsPartial }
        }
        func resume(_ job: ResumableFileTransfer) throws -> UInt64? {
            let b = try backend(); defer { b.cancel() }; var first: UInt64?
            try b.transfer(job) { bytes,_ in if first == nil { first = bytes } }; return first
        }
        func rejects(_ job: ResumableFileTransfer) throws -> Bool {
            let b = try backend(); defer { b.cancel() }
            do { try b.transfer(job) { _,_ in }; return false } catch { return true }
        }
        func remoteFile(_ path: String) -> URL { remote.appendingPathComponent(String(path.drop(while: { $0 == "/" }))) }
        let up = ResumableFileTransfer(local:source,remote:"/resume-upload.bin",upload:true)
        checks["resumeUploadInterrupted"] = try interrupted(up)
        checks["partialUploadNotPublishedAsComplete"] = !FileManager.default.fileExists(atPath:remoteFile(up.remote).path) && FileManager.default.fileExists(atPath:remoteFile(up.remotePartial).path)
        checks["uploadRestartsAtVerifiedOffset"] = try (resume(up) ?? 0) > 0
        checks["resumedUploadExactBytes"] = try Data(contentsOf:remoteFile(up.remote)) == payload
        checks["uploadPartialRemovedOnSuccess"] = !FileManager.default.fileExists(atPath:remoteFile(up.remotePartial).path)
        let down = ResumableFileTransfer(local:local.appendingPathComponent("resume-down.bin"),remote:up.remote,upload:false)
        checks["resumeDownloadInterrupted"] = try interrupted(down)
        checks["partialDownloadNotPublishedAsComplete"] = !FileManager.default.fileExists(atPath:down.local.path) && FileManager.default.fileExists(atPath:down.localPartial.path)
        checks["downloadRestartsAtVerifiedOffset"] = try (resume(down) ?? 0) > 0
        checks["resumedDownloadExactBytes"] = try Data(contentsOf:down.local) == payload
        checks["downloadPartialRemovedOnSuccess"] = !FileManager.default.fileExists(atPath:down.localPartial.path)
        let corrupt = ResumableFileTransfer(local:source,remote:"/resume-corrupt.bin",upload:true)
        _ = try interrupted(corrupt)
        let handle = try FileHandle(forWritingTo:remoteFile(corrupt.remotePartial)); try handle.write(contentsOf:Data([255])); try handle.close()
        let before = try Data(contentsOf:remoteFile(corrupt.remotePartial))
        checks["changedRemotePrefixRejected"] = try rejects(corrupt)
        checks["rejectedUploadDoesNotModifyPartial"] = try Data(contentsOf:remoteFile(corrupt.remotePartial)) == before
        let changed = ResumableFileTransfer(local:source,remote:"/resume-source-changed.bin",upload:true)
        _ = try interrupted(changed); try (payload+Data([1])).write(to:source)
        checks["changedLocalSourceRejected"] = try rejects(changed); try payload.write(to:source)
        let collision = ResumableFileTransfer(local:source,remote:"/resume-collision.bin",upload:true)
        _ = try interrupted(collision); try Data("existing".utf8).write(to:remoteFile(collision.remote))
        checks["existingRemoteDestinationPreserved"] = try rejects(collision) && Data(contentsOf:remoteFile(collision.remote)) == Data("existing".utf8)
        let badDown = ResumableFileTransfer(local:local.appendingPathComponent("resume-bad-down.bin"),remote:up.remote,upload:false)
        _ = try interrupted(badDown)
        let edit = try FileHandle(forWritingTo:badDown.localPartial); try edit.write(contentsOf:Data([255])); try edit.close()
        checks["changedLocalPrefixRejected"] = try rejects(badDown)
        let link = ResumableFileTransfer(local:local.appendingPathComponent("resume-link-down.bin"),remote:up.remote,upload:false)
        _ = try interrupted(link)
        let victim = local.appendingPathComponent("resume-victim.bin"); try Data("untouched".utf8).write(to:victim)
        try FileManager.default.removeItem(at:link.localPartial); try FileManager.default.createSymbolicLink(at:link.localPartial,withDestinationURL:victim)
        checks["partialSymlinkRejected"] = try rejects(link) && Data(contentsOf:victim) == Data("untouched".utf8)
        let remoteChanged = ResumableFileTransfer(local:local.appendingPathComponent("resume-remote-change.bin"),remote:up.remote,upload:false)
        _ = try interrupted(remoteChanged); try (payload+Data([1])).write(to:remoteFile(up.remote))
        checks["changedRemoteSourceRejected"] = try rejects(remoteChanged); try payload.write(to:remoteFile(up.remote))
        let completePartial = ResumableFileTransfer(local:local.appendingPathComponent("resume-full-partial.bin"),remote:up.remote,upload:false)
        checks["completePartialInterruptedBeforeCommit"] = try interrupted(completePartial,atEnd:true)
        checks["completePartialCanFinalizeWithoutRestart"] = try resume(completePartial) == UInt64(payload.count) && Data(contentsOf:completePartial.local) == payload
        let racing = ResumableFileTransfer(local:local.appendingPathComponent("resume-racing.bin"),remote:up.remote,upload:false)
        let racingBackend = try backend(); defer { racingBackend.cancel() }
        var planted = false
        do {
            try racingBackend.transfer(racing) { bytes,total in
                if bytes == total && !planted { planted = true; try? Data("keep-existing".utf8).write(to:racing.local) }
            }
            checks["lateDestinationCollisionRejected"] = false
        } catch { checks["lateDestinationCollisionRejected"] = planted && (try? Data(contentsOf:racing.local)) == Data("keep-existing".utf8) }
        let empty = local.appendingPathComponent("resume-empty.bin"); try Data().write(to:empty)
        let emptyJob = ResumableFileTransfer(local:empty,remote:"/resume-empty.bin",upload:true)
        _ = try resume(emptyJob); checks["emptyResumableUpload"] = try Data(contentsOf:remoteFile(emptyJob.remote)).isEmpty
    }
}
