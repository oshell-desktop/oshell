// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

enum ShellIntegrationTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool](), prefs = Preferences(); prefs.metal = false
        var profile = SessionProfile(name: "集成", host: "192.0.2.1")
        profile.activeHostProbe = false
        let pane = TerminalPane(profile: profile, preferences: prefs, knownHostsFile: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
        checks["explicitModeNeverAllowsProbe"] = !pane.allowsActiveHostProbe
        var legacyProfile = SessionProfile(name: "主动", host: "192.0.2.2"); legacyProfile.activeHostProbe = true
        let automatic = TerminalPane(profile: legacyProfile, preferences: prefs, knownHostsFile: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
        checks["explicitOptInAllowsLegacyProbe"] = automatic.allowsActiveHostProbe
        func frame(_ payload: String) -> String { "\u{1b}]777;OShellHost=1;" + payload + "\u{7}" }
        var name = [CChar](repeating: 0, count: 256); _ = gethostname(&name, name.count)
        let runtimeHost = String(cString: name), localHost = LocalHostIdentity.current().hostname
        let local = TerminalPane(profile: .local, preferences: prefs)
        checks["localStartsWithConfiguredHostname"] = local.title == localHost
        local.terminal.feed(text: "\u{1b}]2;fixture@\(runtimeHost):~\u{7}")
        checks["localOSCTitleDoesNotReplaceConfiguredName"] = local.title == localHost
        local.terminal.feed(text: "\u{1b}]7;file://\(runtimeHost)/tmp\u{7}")
        checks["localOSC7KeepsConfiguredName"] = local.title == localHost
        local.terminal.feed(text: frame("\(runtimeHost)|192.0.2.99|"))
        checks["localIntegrationNormalizesRuntimeAlias"] = local.title == localHost
        local.terminal.feed(text: frame("remote.tail000000.ts.net|192.0.2.98|"))
        checks["nestedRemoteDomainStillRecognized"] = local.title == "remote.tail000000.ts.net"
        local.terminal.feed(text: frame("\(runtimeHost)|192.0.2.99|"))
        checks["returnToLocalRestoresConfiguredName"] = local.title == localHost
        local.shutdown()
        let remote = TerminalPane(profile: profile, preferences: prefs)
        remote.terminal.feed(text: frame("\(runtimeHost)|192.0.2.99|"))
        checks["remoteSSHIdentityNotRewrittenAsLocal"] = remote.title == runtimeHost
        remote.shutdown()
        var passiveProfile = profile; passiveProfile.titleMode = .passive
        let passive = TerminalPane(profile: passiveProfile, preferences: prefs)
        passive.terminal.feed(text: frame("ignored-integration|10.99.0.1|"))
        checks["passiveModeIgnoresIntegration"] = passive.title == "主机待识别" && !passive.hasShellIntegration && passive.remoteAddress == nil
        passive.terminal.feed(text: "\u{1b}]2;ops@passive-host:/srv\u{7}")
        checks["passiveModeUsesOSCHostnameOnly"] = passive.title == "passive-host" && passive.remoteAddress == nil && !passive.allowsActiveHostProbe
        checks["unobservedPeerIsNotGuessedFromConfiguration"] = passive.connectionDetails.contains("实际连接 IP：未获取")
        passive.shutdown()
        func descendants(_ view: NSView) -> [NSView] {
            let children = (view as? NSTabView)?.tabViewItems.compactMap(\.view) ?? view.subviews
            return [view] + children.flatMap(descendants)
        }
        for mode in HostTitleMode.allCases {
            let editor = SessionEditor(profile, profiles: [profile], directories: [], initialDirectory: "")
            let popup = descendants(editor.dialog.accessoryView!).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "session.titleMode" }!
            checks["fourTitleModeChoices"] = popup.itemTitles == SessionTitleDisplayMode.allCases.map(\.title)
            popup.selectItem(at: SessionTitleDisplayMode.allCases.firstIndex(of: SessionTitleDisplayMode(mode))!)
            let timer = Timer(timeInterval: 0.03, repeats: false) { _ in
                if mode == .shellIntegration, let path = ProcessInfo.processInfo.environment["OSHELL_TITLE_MODE_PREVIEW"], let view = editor.dialog.window.contentView {
                    (editor.dialog.accessoryView as? NSTabView)?.selectTabViewItem(withIdentifier: "标签与快捷连接")
                    view.layoutSubtreeIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
                }
                editor.dialog.buttons.first?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
            checks["editorSelectsLocalMode-" + mode.rawValue] = editor.run() != nil && editor.selectedTitleMode == SessionTitleDisplayMode(mode)
        }
        for byte in frame("outer-real|10.20.0.1|").utf8 { pane.terminal.feed(byteArray: [byte][...]) }
        checks["fragmentedMetadataRecognized"] = (pane.title == "outer-real" && pane.remoteAddress == "10.20.0.1") && pane.hasShellIntegration
        checks["metadataDoesNotAppearAsTerminalText"] = !String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("OShellHost")
        automatic.terminal.feed(text: frame("auto|10.30.0.1|"))
        checks["reportAutomaticallyStopsFutureProbes"] = automatic.hasShellIntegration && !automatic.allowsActiveHostProbe
        pane.setTerminalTitle(source: pane.terminal, title: "root@custom-prompt:~")
        checks["integrationWinsOverPromptAlias"] = (pane.title == "outer-real" && pane.remoteAddress == "10.20.0.1")
        let tab = TerminalTab(pane), strip = TabStripView()
        pane.sshConnectionGroup?.transportPeer = SSHTransportPeer(address: "192.0.2.10", port: 2222)
        strip.update(tabs: [tab], selected: tab)
        let tooltip = strip.items.first?.selectButton.toolTip ?? ""
        checks["tabOnlyShowsNumberAndHostname"] = strip.items.first?.selectButton.title == "1  outer-real"
        checks["tooltipGroupsHostAndConnection"] = tooltip.contains("当前主机\n主机名：outer-real\n主机 IP：10.20.0.1") && tooltip.contains("初始 SSH 连接\n会话：集成\n配置地址：192.0.2.1\n端口：22")
        checks["tooltipSeparatesObservedPeer"] = tooltip.contains("实际连接 IP：192.0.2.10\n实际连接端口：2222")
        checks["headerHidesConnectionDetails"] = descendants(pane.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "outer-real" && $0.toolTip?.contains("配置地址：192.0.2.1") == true }
        pane.noteUserInput(Array("ssh inner\r".utf8)[...])
        checks["nestedWithoutScriptDoesNotKeepOuterIP"] = pane.remoteAddress == nil && !pane.allowsActiveHostProbe
        pane.terminal.feed(text: frame("inner-real|10.40.0.1|"))
        checks["nestedReportChangesIdentity"] = (pane.title == "inner-real" && pane.remoteAddress == "10.40.0.1")
        pane.noteUserInput(Array("exit\r".utf8)[...]); pane.terminal.feed(text: frame("outer-real|10.20.0.1|"))
        checks["returnReportRestoresOuter"] = (pane.title == "outer-real" && pane.remoteAddress == "10.20.0.1")
        pane.terminal.feed(text: frame("bad host|10.50.0.1|"))
        checks["invalidMetadataIgnored"] = (pane.title == "outer-real" && pane.remoteAddress == "10.20.0.1")
        pane.terminal.feed(text: "\u{1b}[?1049h" + frame("editor-fake|10.50.0.1|") + "\u{1b}[?1049l")
        checks["alternateScreenMetadataIgnored"] = (pane.title == "outer-real" && pane.remoteAddress == "10.20.0.1")
        pane.terminal.feed(text: "\u{1b}c" + frame("after-reset|10.60.0.1|"))
        checks["terminalResetPreservesReceiver"] = (pane.title == "after-reset" && pane.remoteAddress == "10.60.0.1")
        pane.receive(Data((frame("integrated-real|10.70.0.1|") + "\r\n[root@alias ~]# ").utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            checks["reportedNameSurvivesPromptAlias"] = (pane.title == "integrated-real" && pane.remoteAddress == "10.70.0.1")
            // A host switch performed by an alias may not be visible as 'ssh' input.
            pane.receive(Data("\r\n[root@plain-inner ~]# ".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                checks["missingIntegrationFallsBackToDifferentPrompt"] = (pane.title == "plain-inner" && pane.remoteAddress == nil) && !pane.allowsActiveHostProbe
                pane.terminal.feed(text: "\u{1b}]0;ops@osc-inner:/srv\u{7}")
                checks["passiveOSCTitleStillUpdates"] = (pane.title == "osc-inner" && pane.remoteAddress == nil)
                pane.terminal.feed(text: "\u{1b}]7;file://directory-host/srv\u{7}")
                checks["passiveOSC7StillUpdates"] = (pane.title == "directory-host" && pane.remoteAddress == nil)
                let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                if let path = ProcessInfo.processInfo.environment["OSHELL_SHELL_INTEGRATION_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
                print(report); pane.shutdown(); automatic.shutdown(); controller.shutdown(); NSApp.terminate(nil)
            }
        }
    }
}
