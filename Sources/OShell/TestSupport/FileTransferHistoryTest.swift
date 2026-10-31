// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

private final class HistoryTestBackend: RemoteFileBackend {
    let description = "History fixture"
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var cancelled = false
    func connect() throws {}
    func canonicalPath(_ path: String) throws -> String { path }
    static func entry(_ name: String, directory: Bool = false) -> RemoteFileEntry { .init(name: name, size: 3, modified: nil, directory: directory, symbolicLink: false) }
    func list(_ path: String) throws -> [RemoteFileEntry] { [Self.entry("a.txt")] }
    func upload(_ local: URL, to remote: String, progress: @escaping (UInt64, UInt64) -> Void) throws { progress(1,3); progress(3,3) }
    func download(_ remote: String, to local: URL, progress: @escaping (UInt64, UInt64) -> Void) throws {
        if remote.contains("bad") { throw ModelError.invalid("模拟下载失败") }
        if remote.contains("slow") {
            progress(1,3); _ = gate.wait(timeout: .now()+8)
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw ModelError.invalid("模拟取消后的迟到错误") }
        }
        try Data("abc".utf8).write(to: local); progress(3,3)
    }
    func mkdir(_ path: String) throws {}
    func rename(_ source: String, to destination: String) throws {}
    func remove(_ path: String, directory: Bool) throws {}
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); gate.signal() }
}

enum FileTransferHistoryTest {
    static func run(_ workspace: WorkspaceController) {
        RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in exercise(workspace) }, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool](), finished = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-history-"+UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("a.txt"), folder = root.appendingPathComponent("folder")
        try! Data("abc".utf8).write(to: file); try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let session = RemoteFileSession(workspace: workspace, backendFactory: { _ in HistoryTestBackend() })
        let peer = RemoteFileSession(workspace: workspace, backendFactory: { _ in HistoryTestBackend() })
        let profile = SessionProfile(name: "history fixture", host: "127.0.0.1", username: "fixture")
        func views(_ v: NSView) -> [NSView] { [v]+v.subviews.flatMap(views) }
        func finish() {
            guard !finished else { return }; finished = true
            session.shutdown(); peer.shutdown(); checks["closingClearsHistory"] = session.transferHistory.snapshot.isEmpty
            try? FileManager.default.removeItem(at: root)
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            if let path = ProcessInfo.processInfo.environment["OSHELL_FILE_HISTORY_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path)) }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ name: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(12)
            func poll() {
                guard !finished else { return }
                if condition() { checks[name] = true; next() }
                else if Date() >= deadline { checks[name] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now()+0.05, execute: poll) }
            }; poll()
        }
        let history = FileTransferHistory(limit: 20), batch = UUID()
        func add(_ h: FileTransferHistory, _ token: UUID) -> UUID { h.enqueue(batch: token, upload: true, transport: "SCP", local: "/fixture/local", remote: "/fixture/remote") }
        let completed = add(history,batch), active = add(history,batch), queued = add(history,batch)
        _ = history.start(completed); history.succeed(completed); _ = history.start(active); history.progress(active,bytes:1,total:3)
        history.finishBatch(batch,error: ModelError.invalid("fixture error"))
        checks["partialSuccessStaysSuccessful"] = history.snapshot.first { $0.id == completed }?.state == .succeeded
        checks["failureAndUnstartedSeparated"] = history.snapshot.first { $0.id == active }?.state == .failed && history.snapshot.first { $0.id == queued }?.state == .skipped
        let cancellation = UUID(), pending = add(history,cancellation); _ = history.start(pending); history.cancel(cancellation); history.succeed(pending); history.progress(pending,bytes:3,total:3)
        checks["lateSuccessCannotOverwriteCancellation"] = history.snapshot.first { $0.id == pending }?.state == .cancelled
        let bounded = FileTransferHistory(limit: 2), waitingBatch = UUID()
        let waiting = add(bounded,waitingBatch)
        for _ in 0..<5 { let id=add(bounded,UUID()); _=bounded.start(id); bounded.succeed(id) }
        checks["boundedCompletedHistoryKeepsWaiting"] = bounded.snapshot.count == 3 && bounded.snapshot.contains { $0.id == waiting }
        bounded.clearCompleted(); checks["clearKeepsUnfinished"] = bounded.snapshot.map(\.id) == [waiting]
        let large = FileTransferHistory(limit: 2), largeBatch = UUID()
        let started = ProcessInfo.processInfo.systemUptime
        let bulk = (0..<20_000).map { _ in add(large, largeBatch) }
        let enqueueMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        checks["largeBatchKeepsAllQueuedRecords"] = large.snapshot.count == bulk.count
        _ = large.start(bulk[0]); large.pause(largeBatch)
        checks["pauseTrimsSkippedAndPreservesPaused"] = large.snapshot.map(\.id) == [bulk[0]] + Array(bulk.suffix(2)) && large.snapshot.first?.state == .paused
        let retryBatch = UUID()
        checks["pausedRecordCanResumeAfterTrim"] = large.requeue(bulk[0], batch: retryBatch) && large.start(bulk[0])
        large.progress(bulk[0], bytes: 42, total: 42); large.succeed(bulk[0])
        checks["completionStillBoundsHistory"] = large.snapshot.count == 2 && large.snapshot.allSatisfy { $0.state.finished }
        let cancellationBatch = UUID()
        for _ in 0..<5 { _ = add(large, cancellationBatch) }
        large.cancel(cancellationBatch)
        checks["cancellationStillBoundsHistory"] = large.snapshot.count == 2 && large.snapshot.allSatisfy { $0.state == .cancelled }
        print("Synthetic history enqueue: 20000 records, \(enqueueMilliseconds) ms")
        let preparation = FileTransferHistory(), setup = UUID(); _=add(preparation,setup); _=add(preparation,setup); preparation.finishBatch(setup,error:ModelError.invalid("fixture setup"))
        checks["preparationFailureRecorded"] = preparation.snapshot.map(\.state) == [.failed,.skipped]
        session.view.setFrameSize(NSSize(width: 776, height: 450)); session.view.layoutSubtreeIfNeeded()
        let browser = views(session.view).compactMap { $0 as? FileTableView }.first!
        let originalHeight = browser.enclosingScrollView!.frame.height
        session.connect(profile,directory:"/fixture")
        wait("connected", { session.connected && !session.hasActiveOperation }) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in NSApp.stopModal(withCode: .alertFirstButtonReturn) }
            RunLoop.main.add(timer, forMode:.common); RunLoop.main.add(timer,forMode:.modalPanel)
            session.upload([file,folder],to:"/fixture")
            wait("uploadFinished", { !session.hasActiveOperation }) {
                let records = session.transferHistory.snapshot
                checks["oneRecordPerUploadItem"] = records.count == 2 && records.allSatisfy { $0.upload && $0.state == .succeeded && $0.started != nil && $0.ended != nil }
                checks["resolvedRemoteNameRecorded"] = records.first?.remote == "/fixture/a.txt.1"
                checks["fastTransferBytesNotLost"] = records.first?.bytes == 3 && records.first?.total == 3
                checks["directoryDoesNotClaimSingleFileTotal"] = records.last?.directory == true && records.last?.amount == "目录（含子项）"
                checks["peerHistoryIsIndependent"] = peer.transferHistory.snapshot.isEmpty
                session.view.layoutSubtreeIfNeeded()
                let table = views(session.view).compactMap { $0 as? NSTableView }.first { $0.identifier?.rawValue == "files.transferHistory" }!
                checks["historyPanelShowsRecords"] = !table.isHiddenOrHasHiddenAncestor && table.numberOfRows == 2
                checks["historyPanelFitsMinimumWindow"] = browser.enclosingScrollView!.frame.height > 60 && session.view.bounds.contains(table.enclosingScrollView!.convert(table.enclosingScrollView!.bounds,to:session.view))
                session.toggleHistory(); session.view.layoutSubtreeIfNeeded()
                checks["hideRestoresBrowserArea"] = table.isHiddenOrHasHiddenAncestor && browser.enclosingScrollView!.frame.height >= originalHeight-1
                session.toggleHistory()
                session.download([HistoryTestBackend.entry("a.txt"),HistoryTestBackend.entry("bad.txt"),HistoryTestBackend.entry("never.txt")],from:"/fixture",to:root)
                wait("downloadBatchEnded", { !session.hasActiveOperation }) {
                    let downloads = session.transferHistory.snapshot.filter { !$0.upload }
                    checks["downloadPartialFailure"] = downloads.map(\.state) == [.succeeded,.failed,.skipped]
                    checks["resolvedLocalNameRecorded"] = downloads.first?.local == root.appendingPathComponent("a.txt.1").path
                    checks["errorRetained"] = downloads[1].error.contains("模拟下载失败")
                    checks["detailsHaveBothPaths"] = downloads[0].detail.contains("本地：") && downloads[0].detail.contains("远程：/fixture/a.txt")
                    let count = session.transferHistory.snapshot.count
                    session.connect(profile,directory:"/fixture")
                    wait("reconnected", { session.connected && !session.hasActiveOperation }) {
                        checks["reconnectRetainsHistory"] = session.transferHistory.snapshot.count == count
                        session.download([HistoryTestBackend.entry("slow.txt"),HistoryTestBackend.entry("queued.txt")],from:"/fixture",to:root)
                        wait("transferRunning", { session.transferHistory.snapshot.contains { $0.state == .running } }) {
                            session.cancelFileOperation()
                            checks["cancelMarksRunningAndQueued"] = session.transferHistory.snapshot.suffix(2).allSatisfy { $0.state == .cancelled }
                            session.connect(profile,directory:"/fixture")
                            wait("reconnectDrainsCancelledWorker", { session.connected && !session.hasActiveOperation }) {
                                checks["lateWorkerCannotChangeHistory"] = session.transferHistory.snapshot.suffix(2).allSatisfy { $0.state == .cancelled }
                                var other = profile; other.id = UUID(); session.connect(other,directory:"/fixture")
                                checks["differentSessionClearsHistory"] = session.transferHistory.snapshot.isEmpty
                                wait("differentSessionConnected", { session.connected && !session.hasActiveOperation },finish)
                            }
                        }
                    }
                }
            }
        }
    }
}
