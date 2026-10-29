// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// Real rsync over the same authenticated, one-use SSH fixture as SFTP/SCP.
enum RsyncTransferChecks {
    static func run(profile: SessionProfile, knownHosts: URL, group: SSHConnectionGroup, root: URL) -> [String: Bool] {
        var checks = [String: Bool]()
        do {
            let task = try RsyncTransfer(profile: profile, knownHosts: knownHosts, connectionGroup: group)
            let source = root.appendingPathComponent("rsync source '中文' ;$().txt"), destination = root.appendingPathComponent("rsync-download.txt")
            let bytes = Data("rsync real fixture\n".utf8), remote = "/rsync '中文' ;$() [*].txt"
            try bytes.write(to: source)
            try task.run(local: source, remote: remote, upload: true, directory: false)
            try task.run(local: destination, remote: remote, upload: false, directory: false)
            checks["rsyncQuotedFileRoundTrip"] = try Data(contentsOf: destination) == bytes
            let folder = root.appendingPathComponent("rsync-tree"), child = folder.appendingPathComponent("nested/资料.txt")
            try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: 128 * 1024).write(to: child)
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("safe-link").path, withDestinationPath: "nested/资料.txt")
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("outside-link").path, withDestinationPath: "../../outside")
            var processed: UInt64 = 0
            let tree = "/rsync tree '中文'"
            try task.run(local: folder, remote: tree, upload: true, directory: true) { bytes, _ in processed = max(processed, bytes) }
            checks["rsyncReportsProgress"] = processed >= 128 * 1024
            let physicalTree = root.appendingPathComponent("remote" + tree)
            let untouched = physicalTree.appendingPathComponent("keep.txt")
            try Data("keep remote".utf8).write(to: untouched)
            let changed = Data("updated content with different size\n".utf8); try changed.write(to: child)
            try task.run(local: folder, remote: tree, upload: true, directory: true)
            checks["rsyncUpdatesSamePathWithoutNesting"] = try Data(contentsOf: physicalTree.appendingPathComponent("nested/资料.txt")) == changed
            checks["rsyncPreservesDestinationOnlyFiles"] = try Data(contentsOf: untouched) == Data("keep remote".utf8)
            processed = 0
            try task.run(local: folder, remote: tree, upload: true, directory: true) { bytes, _ in processed = max(processed, bytes) }
            checks["rsyncSkipsUnchangedFiles"] = processed == 0
            let copy = root.appendingPathComponent("rsync-copy")
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
            try Data("keep local".utf8).write(to: copy.appendingPathComponent("local-only.txt"))
            try task.run(local: copy, remote: tree, upload: false, directory: true)
            checks["rsyncDirectoryDownloadMergesContents"] = try Data(contentsOf: copy.appendingPathComponent("nested/资料.txt")) == changed && FileManager.default.fileExists(atPath: copy.appendingPathComponent("local-only.txt").path)
            checks["rsyncSafeSymlinks"] = (try? FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("safe-link").path)) == "nested/资料.txt" && !FileManager.default.fileExists(atPath: copy.appendingPathComponent("outside-link").path)
            let alias = root.appendingPathComponent("rsync-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: copy)
            do { try task.run(local: alias, remote: tree, upload: false, directory: true); checks["rsyncRejectsLocalSymlinkRoot"] = false } catch { checks["rsyncRejectsLocalSymlinkRoot"] = true }
            let marker = root.appendingPathComponent("missing-rsync"); try Data().write(to: marker)
            do { try task.run(local: source, remote: "/missing", upload: true, directory: false); checks["rsyncMissingRemoteReported"] = false }
            catch { checks["rsyncMissingRemoteReported"] = error.localizedDescription.contains("rsync") }
            try FileManager.default.removeItem(at: marker)
            let limited = try RsyncTransfer(profile: profile, knownHosts: knownHosts, connectionGroup: group, rateLimit: 65536)
            let large = root.appendingPathComponent("rsync-cancel.bin"); try Data(repeating: 19, count: 2 * 1024 * 1024).write(to: large)
            let began = ProcessInfo.processInfo.systemUptime
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { limited.cancel() }
            do { try limited.run(local: large, remote: "/rsync-cancel.bin", upload: true, directory: false); checks["rsyncCancelInterruptsLimitedTransfer"] = false }
            catch { checks["rsyncCancelInterruptsLimitedTransfer"] = ProcessInfo.processInfo.systemUptime - began < 5 }
            checks["rsyncCancelPreservesSSH"] = group.isAvailable
            let afterCancel = try SFTPBackend(profile: profile, knownHosts: knownHosts, connectionGroup: group)
            defer { afterCancel.cancel() }
            try afterCancel.connect()
            checks["rsyncCancelAllowsImmediateSFTP"] = try afterCancel.list("/").contains { $0.name == "seed.txt" }
            let retry = try RsyncTransfer(profile: profile, knownHosts: knownHosts, connectionGroup: group)
            try retry.run(local: large, remote: "/rsync-cancel.bin", upload: true, directory: false)
            checks["rsyncRetryCompletesCancelledDestination"] = try Data(contentsOf: root.appendingPathComponent("remote/rsync-cancel.bin")) == Data(contentsOf: large)
            // More than the old stdout cap must not grow the parser's retained data.
            let parser = RsyncProgressParser { bytes, percent in if bytes == 1_024 && percent == 50 { checks["rsyncChunkedProgress"] = true } }
            parser.consume(Data(repeating: 65, count: 5 * 1024 * 1024)); parser.consume(Data("\nOSHELL_RSYNC_FILE:2048\n 1,0".utf8)); parser.consume(Data("24 50% 2kB/s\r".utf8))
            checks["rsyncChunkedProgress"] = checks["rsyncChunkedProgress"] == true
        } catch {
            checks["rsyncUnexpectedFailure"] = false
            NSLog("Rsync synthetic fixture: %@", error.localizedDescription)
        }
        return checks
    }
    static func runUI(_ session: RemoteFileSession, root: URL, done: @escaping ([String: Bool]) -> Void) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func wait(_ name: String, _ test: @escaping () -> Bool, then: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                if test() { checks[name] = true; then() }
                else if Date() > deadline { checks[name] = false; done(checks) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
            }; poll()
        }
        guard let mode = descendants(session.view).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.identifier?.rawValue == "files.transferMode" }) else { done(["rsyncModeAvailable": false]); return }
        mode.selectItem(withTitle: "rsync 增量传输"); checks["rsyncModeAvailable"] = mode.indexOfSelectedItem == 2
        let local = root.appendingPathComponent("ui-rsync.txt"), remote = root.appendingPathComponent("remote/ui-rsync.txt")
        try? Data("UI rsync first".utf8).write(to: local)
        session.upload([local], to: "/")
        wait("rsyncUIUploadCompletes", { !session.hasActiveOperation }) {
            checks["rsyncUIRecordsTransport"] = session.transferHistory.snapshot.last?.transport == "rsync" && session.transferHistory.snapshot.last?.state == .succeeded
            let updated = Data("UI rsync updated longer content".utf8); try? updated.write(to: local)
            session.upload([local], to: "/")
            wait("rsyncUIUpdateCompletes", { !session.hasActiveOperation }) {
                checks["rsyncUIUpdatesInsteadOfRenaming"] = (try? Data(contentsOf: remote)) == updated && !FileManager.default.fileExists(atPath: remote.path + ".1")
                let destination = root.appendingPathComponent("ui-download")
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                session.download([RemoteFileEntry(name: "ui-rsync.txt", size: UInt64(updated.count), modified: nil, directory: false, symbolicLink: false)], from: "/", to: destination)
                wait("rsyncUIDownloadCompletes", { !session.hasActiveOperation }) {
                    checks["rsyncUIDownloadMatches"] = (try? Data(contentsOf: destination.appendingPathComponent("ui-rsync.txt"))) == updated && session.transferHistory.snapshot.last?.state == .succeeded
                    session.cancelFileOperation()
                    session.synchronizeRsyncDirectory(local: destination, remote: "/ui-sync", upload: true)
                    wait("rsyncUIStandaloneCompletes", { !session.hasActiveOperation }) {
                        checks["rsyncWorksWithoutSFTPBrowser"] = !session.connected && (try? Data(contentsOf: root.appendingPathComponent("remote/ui-sync/ui-rsync.txt"))) == updated && session.transferHistory.snapshot.last?.state == .succeeded
                        descendants(session.view).compactMap { $0 as? NSButton }.first { $0.title == "重连" }?.performClick(nil)
                        wait("rsyncUIReconnectRestoresSFTP", { session.connected && !session.hasActiveOperation }) { done(checks) }
                    }
                }
            }
        }
    }

}
