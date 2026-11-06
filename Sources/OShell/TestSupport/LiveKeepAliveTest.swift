// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum LiveKeepAliveTest {
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_IDENTITY_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        var checks = [String: Bool](), finished = false
        func trace(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
        func finish() {
            guard !finished else { return }; finished = true
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
            controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
            trace("wait: " + label)
            let deadline = Date().addingTimeInterval(12)
            func poll() {
                guard !finished else { return }
                if condition() { trace("pass: " + label); checks[label] = true; next() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
            }; poll()
        }
        func modalTimer(_ delay: TimeInterval, _ body: @escaping () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in body() }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        do {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
            try controller.store.save(controller.configuration)
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
            let request = try ZOCLaunchRequest.parse(["/DEV:SSH", "/CONNECT:test:\(fixture["password"] as! String)@127.0.0.1:\(fixture["outerPort"] as! Int)"])
            var gateway = try request.profile(), keep = gateway.keepAlive
            keep.enabled = true; keep.interval = 41; keep.idleEnabled = false
            try ExternalKeepAliveSettings.save(keep, for: gateway)
            gateway.id = UUID(); gateway.username = "new-one-time-user"
            checks["webLaunchPreferencesSurviveNewIDAndAccount"] = try ExternalKeepAliveSettings.applying(to: gateway).keepAlive == keep
            var otherGateway = gateway; otherGateway.port += 1
            checks["gatewayPortSeparatesPreferences"] = try ExternalKeepAliveSettings.applying(to: otherGateway).keepAlive != keep
            let stored = try String(contentsOf: ExternalKeepAliveSettings.url, encoding: .utf8)
            checks["gatewayPreferencesContainNoCredential"] = !stored.contains(gateway.username) && !stored.contains(fixture["password"] as! String)
            controller.openExternal(request)
            let tab = controller.selectedTab!, pane = tab.activePane
            func text() -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
            func count(_ token: String) -> Int { text().components(separatedBy: "\n" + token + "\n").count - 1 }
            func sentC() -> Int {
                guard let data = try? Data(contentsOf: root.appendingPathComponent("idle-inputs.json")),
                      let counters = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return -1 }
                return counters["C"] ?? -1
            }
            wait("connected", { pane.canEditLiveKeepAlive && pane.title == "outer-real" }) {
                let pid = pane.terminal.process.shellPid, startup = pane.profile.keepAlive
                var config = controller.configuration; config.profiles = [pane.profile]
                config.profiles[0].keepAlive.interval = 77 // A future-connection setting must survive saving idle options.
                checks["savedFixture"] = controller.saveConfiguration(config)
                controller.duplicateTab(tab); let other = controller.selectedTab!.activePane
                wait("cloneConnected", { other.canEditLiveKeepAlive }) {
                    let properties = controller.sessionTabContextMenu(tab.id).items.first { $0.title == "当前会话属性…" }!
                    checks["contextTargetsSourceTab"] = properties.representedObject as? UUID == tab.id && properties.isEnabled
                    modalTimer(0.05) {
                        guard let root = NSApp.modalWindow?.contentView else { trace("no modal window"); return }
                        trace("driving modal")
                        let controls = descendants(root)
                        let enabled = controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "live.idleEnabled" }!
                        if enabled.state == .off { enabled.performClick(nil) }
                        controls.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "live.idleInterval" }?.stringValue = "1"
                        controls.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "live.idleText" }?.stringValue = "echo LIVE_A\\r"
                        controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "live.persist" }?.state = .off
                        controls.compactMap { $0 as? NSButton }.first { $0.title == "立即应用" }?.performClick(nil)
                    }
                    trace("opening properties")
                    modalTimer(8) {
                        if let window = NSApp.modalWindow { trace("watchdog dismissing modal"); _ = PopupKeyboard.dismiss(window: window) }
                    }
                    _ = NSApp.sendAction(properties.action!, to: properties.target, from: properties)
                    trace("properties returned")
                    checks["dialogAppliesToCorrectPane"] = pane.profile.keepAlive.idleEnabled && !other.profile.keepAlive.idleEnabled
                    checks["runtimeOnlyDoesNotSave"] = !controller.configuration.profiles[0].keepAlive.idleEnabled
                    wait("newTimerSendsA", { count("LIVE_A") > 0 }) {
                        var next = pane.profile.keepAlive; next.idleInterval = 2; next.idleText = "echo LIVE_B\\r"
                        do { try controller.applyLiveIdleKeepAlive(paneID: pane.id, settings: next, persist: true) }
                        catch { checks["applyB"] = false; finish(); return }
                        checks["savedOnlyIdleFields"] = controller.configuration.profiles[0].keepAlive.interval == 77 && (try? ExternalKeepAliveSettings.applying(to: pane.profile).keepAlive.idleText) == next.idleText
                        wait("changedTimerSendsB", { count("LIVE_B") > 0 }) {
                            let a = count("LIVE_A"), b = count("LIVE_B")
                            var stopped = pane.profile.keepAlive; stopped.idleEnabled = false
                            try? pane.applyIdleKeepAlive(stopped)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                                checks["disableStopsAllTimers"] = count("LIVE_A") == a && count("LIVE_B") == b
                                checks["protocolOptionsUnchanged"] = pane.profile.keepAlive.enabled == startup.enabled && pane.profile.keepAlive.interval == startup.interval && pane.profile.keepAlive.maxMissed == startup.maxMissed && pane.profile.keepAlive.tcp == startup.tcp
                                checks["sameProcessNoReconnect"] = pane.terminal.process.shellPid == pid && pane.canEditLiveKeepAlive
                                let before = pane.profile.keepAlive
                                modalTimer(0.05) { if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
                                controller.showSessionProperties(tabID: tab.id)
                                checks["cancelDoesNotChangeRuntime"] = pane.profile.keepAlive == before
                                var protected = before; protected.idleEnabled = true; protected.idleInterval = 1; protected.idleText = "echo LIVE_C\\r"
                                try? pane.applyIdleKeepAlive(protected)
                                pane.sendManaged(Array("echo PARTIAL".utf8))
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    checks["doesNotInterruptEditing"] = count("LIVE_C") == 0 && text().contains("echo PARTIAL")
                                    pane.sendManaged([21])
                                    wait("resumesAfterEditingCleared", { count("LIVE_C") > 0 }) {
                                        let c = sentC(); checks["serverCountsIdleBytes"] = c > 0
                                        pane.receive(Data("\r\nPassword: ".utf8))
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            checks["passwordPromptProtected"] = sentC() == c
                                            pane.receive(Data("\r\n[root@asset ~]# \u{1b}[?1049h".utf8))
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                                checks["alternateScreenProtected"] = sentC() == c
                                                pane.receive(Data("\u{1b}[?1049l".utf8))
                                                pane.shutdown()
                                                checks["endedPaneNotEditable"] = !pane.canEditLiveKeepAlive
                                                checks["closedPaneRejectsApply"] = (try? pane.applyIdleKeepAlive(protected)) == nil
                                                checks["otherConnectionUnaffected"] = other.canEditLiveKeepAlive && !other.profile.keepAlive.idleEnabled
                                                checks["persistedAfterReload"] = (try? ExternalKeepAliveSettings.applying(to: request.profile()).keepAlive.idleText) == "echo LIVE_B\\r"
                                                finish()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch { checks["setup"] = false; finish() }
    }
}
