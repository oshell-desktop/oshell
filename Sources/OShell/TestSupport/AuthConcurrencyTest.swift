// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import OShellCore

/// Real broker sockets and modal password windows; synthetic credentials only.
final class AuthConcurrencyTest {
    private static var retained: AuthConcurrencyTest?
    private let workspace: WorkspaceController
    private var brokers = [AuthBroker](), profiles = [SessionProfile]()
    private var replies = [Int: AuthResponse](), checks = [String: Bool]()
    private var shown = Set<Int>(), timer: Timer?, heldSince: Date?
    private var queued = false, cancelledPending = false, cancelledActive = false, retrying = false, finished = false, ready = false
    private let deadline = Date().addingTimeInterval(35)
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = AuthConcurrencyTest(workspace); retained = test; test.start()
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func start() {
        do {
            PasswordVault.shared.decrypt(SessionProfile(name: "No saved credential", host: "192.0.2.99", username: "fixture")) { [self] result in
                if case .failure = result { checks["missingCredentialCompletesRequest"] = true }
                else { checks["missingCredentialCompletesRequest"] = false }
            }
            for index in 0..<5 {
                let profile = SessionProfile(name: "Concurrent fixture \(index)", host: "192.0.2.\(index + 10)", username: "fixture")
                profiles.append(profile); brokers.append(try AuthBroker(profile: profile))
            }
            brokers[3].onAuthenticated = { [weak self] in self?.ready = true }
            timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common); RunLoop.main.add(timer!, forMode: .modalPanel)
            request(brokers[0], index: 0)
        } catch { checks["setup"] = false; finish() }
    }
    private func request(_ broker: AuthBroker, index: Int, ready: Bool = false) {
        let env = broker.environment
        DispatchQueue.global().async { [weak self] in
            let response = try? AuthIPC.request(socketPath: env["OSHELL_AUTH_SOCKET"]!, request: AuthRequest(token: env["OSHELL_AUTH_TOKEN"]!, prompt: "Password for fixture \(index):", hint: ready ? "oshell-session-ready" : ""))
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if ready { self.checks["readyReplyWhileOtherPromptOpen"] = response?.success == true }
                else { self.replies[index] = response ?? AuthResponse(success: false) }
            }
        }
    }
    private func abandonedRequest() {
        let env = brokers[4].environment
        DispatchQueue.global().async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { return }; defer { close(fd) }
            guard var address = try? AuthIPC.address(env["OSHELL_AUTH_SOCKET"]!) else { return }
            let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if result == 0 { try? AuthIPC.write(AuthRequest(token: env["OSHELL_AUTH_TOKEN"]!, prompt: "Abandoned fixture", hint: ""), fd: fd) }
        }
    }
    private func tick() {
        guard !finished else { return }
        if Date() > deadline { checks["completedBeforeTimeout"] = false; finish(); return }
        if let window = NSApp.modalWindow, let root = window.contentView {
            let controls = views(root)
            if let input = controls.compactMap({ $0 as? NSSecureTextField }).first(where: { $0.identifier?.rawValue == "ssh.auth.password" }),
               let label = controls.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue.hasPrefix("Concurrent fixture ") }),
               let digit = label.stringValue.split(separator: "\n").first?.split(separator: " ").last, let index = Int(digit) {
                shown.insert(index)
                if !retrying && index == 0 {
                    if !queued {
                        queued = true; heldSince = Date()
                        for next in 1...3 { request(brokers[next], index: next) }
                        request(brokers[3], index: 3, ready: true); abandonedRequest()
                    }
                    let elapsed = Date().timeIntervalSince(heldSince!)
                    if elapsed > 0.5 && !cancelledPending {
                        cancelledPending = true; brokers[1].stop()
                        checks["mainQueueProcessesReadyWhilePromptOpen"] = ready
                    }
                    if elapsed > 1 && !cancelledActive { cancelledActive = true; brokers[0].stop() }
                    return
                }
                if !retrying && !cancelledActive { checks["authenticationWindowsNeverNest"] = false }
                input.stringValue = "fixture-answer-\(index)"
                controls.compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil)
            }
        }
        if !retrying && (0...3).allSatisfy({ replies[$0] != nil }) {
            checks["activeCancellationFailsOnlyOwnRequest"] = replies[0]?.success == false
            checks["pendingCancellationFailsOnlyOwnRequest"] = replies[1]?.success == false && !shown.contains(1)
            checks["otherSessionsReceiveOwnPasswords"] = (2...3).allSatisfy { replies[$0]?.success == true && replies[$0]?.answer == "fixture-answer-\($0)" }
            checks["authenticationWindowsNeverNest"] = checks["authenticationWindowsNeverNest"] ?? true
            checks["closedClientDoesNotShowStalePrompt"] = !shown.contains(4)
            retrying = true
            do {
                let fresh = try AuthBroker(profile: profiles[1]); brokers.append(fresh); request(fresh, index: 5)
            } catch { checks["retrySetup"] = false; finish() }
        }
        if retrying, let reply = replies[5] {
            checks["cancelledSessionReconnectCanPromptAgain"] = reply.success && reply.answer == "fixture-answer-1"
            checks["closedClientDoesNotShowStalePrompt"] = !shown.contains(4)
            checks["allPromptsDismissed"] = NSApp.modalWindow == nil
            finish()
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true; timer?.invalidate(); timer = nil
        brokers.forEach { $0.stop() }; brokers = []
        if let path = ProcessInfo.processInfo.environment["OSHELL_AUTH_CONCURRENCY_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed":checks.values.allSatisfy { $0 }, "checks":checks], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath:path))
        }
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}
