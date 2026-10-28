// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import OShellCore
import SwiftTerm

/// Synthetic 128 MiB archive plus repeated close/cancel cycles; never opens user records.
final class AgentResourceTest {
    private static var retained: AgentResourceTest?
    private let workspace: WorkspaceController, report: URL
    private var checks = [String: Bool](), measurements = [String: Double]()
    private var round = 0
    private init(_ workspace: WorkspaceController, report: URL) { self.workspace = workspace; self.report = report }
    static func run(_ workspace: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_AGENT_RESOURCES_OUTPUT"] else { return }
        let test = AgentResourceTest(workspace, report: URL(fileURLWithPath: path)); retained = test
        DispatchQueue.global(qos: .utility).async {
            do {
                let url = try test.prepareAndScan()
                DispatchQueue.main.async { test.cycle(url) }
            } catch { DispatchQueue.main.async { test.checks["fixture"] = false; test.finish(error.localizedDescription) } }
        }
    }
    private static func heap() -> Int { var value = malloc_statistics_t(); malloc_zone_statistics(nil, &value); return value.size_in_use }
    private static func descriptors() -> Int { (0..<4096).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
    private func prepareAndScan() throws -> URL {
        let audit = try AgentAudit(directory: AgentPrivateStore.root, metadata: ["title": .string("synthetic memory archive"), "cols": .number(80), "rows": .number(24)])
        let payload = Data(repeating: 65, count: 65_536)
        for index in 0..<2048 {
            guard audit.append(.init(kind: "display", bytes: payload)) else { throw ModelError.invalid("fixture queue overflow") }
            if index % 4 == 3 { audit.flush() }
        }
        audit.finish(reason: "synthetic memory fixture"); audit.flush()
        let key = try AgentAudit.key(directory: AgentPrivateStore.root, create: false)
        // Warm the codec once before measuring steady-state scanning.
        var warm = 0
        try AgentAudit.read(url: audit.url, key: key) { _ in warm += 1; return warm < 32 }
        let baseline = Self.heap(), fds = Self.descriptors()
        var peak = baseline, total = 0
        for _ in 0..<3 {
            let complete = try AgentAudit.read(url: audit.url, key: key) { event in
                total += event.bytes?.count ?? 0
                if event.sequence % 32 == 0 { peak = max(peak, Self.heap()) }
                return true
            }
            if !complete { throw ModelError.invalid("unsealed fixture") }
        }
        checks["threeFullScansPreserveBytes"] = total == 3 * 128 * 1024 * 1024
        checks["scanHeapGrowthUnder16MiB"] = peak - baseline < 16 * 1024 * 1024
        checks["scanReadersCloseDescriptors"] = Self.descriptors() <= fds
        checks["auditQueueBounded"] = audit.peakQueuedBytes <= AgentAudit.maximumQueuedBytes
        measurements["scanPayloadMiB"] = 384
        measurements["scanHeapGrowthMiB"] = Double(max(0, peak - baseline)) / 1048576
        measurements["auditQueuePeakKiB"] = Double(audit.peakQueuedBytes) / 1024
        return audit.url
    }
    private func cycle(_ url: URL) {
        round += 1
        var owner: AgentArchiveWindow? = AgentArchiveWindow()
        weak var released = owner
        weak var terminal = owner?.replayTerminalForTesting
        let timer = owner?.timerForTesting
        // Leave the eight-record producer paused while superseding whole-archive scans.
        for _ in 0..<40 { owner?.selectForTesting(url) }
        let jobs = owner?.workForTesting ?? []
        owner?.close(); owner = nil
        weak var pane: TerminalPane?
        autoreleasepool {
            let disposable = TerminalPane(profile: .local, preferences: Preferences(), blank: true)
            pane = disposable; workspace.getAIAssistant().bind(disposable); disposable.shutdown()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.checks["round\(self.round)WindowAndTerminalReleased"] = released == nil && terminal == nil
            self.checks["round\(self.round)TimerStopped"] = timer?.isValid == false
            self.checks["round\(self.round)ScansStopped"] = jobs.allSatisfy { $0.isFinished }
            self.checks["round\(self.round)PanelDoesNotRetainPane"] = pane == nil
            if self.round < 3 { self.cycle(url) } else { self.finish() }
        }
    }
    private func finish(_ error: String? = nil) {
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 } && error == nil, "checks": checks, "measurements": measurements, "error": error ?? ""]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}
