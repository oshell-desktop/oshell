// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum QuickConnectDetailsTest {
    private final class ActionProbe: NSObject {
        var calls = 0
        @objc func connect(_ sender: NSMenuItem) { calls += 1 }
    }
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            var checks = [String: Bool]()
            var ssh = SessionProfile(name: "生产服务器", group: "测试", host: "host.example.invalid", port: 2222, username: "ops")
            ssh.initialDirectory = "/srv/project"; ssh.identityFile = "/fixture/PRIVATE_KEY_PATH"
            var hop = ProxySettings(); hop.kind = .jump; hop.host = "2001:db8::1"; hop.port = 2200; hop.username = "jump"
            hop.identityFile = "/fixture/PROXY_PRIVATE_KEY_PATH"
            let proxy = ProxyProfile(name: "测试跳板", settings: hop)
            ssh.proxyID = proxy.id
            let ftp = SessionProfile(name: "文件服务器", group: "测试", kind: .ftp, host: "ftp.example.invalid", port: 2121, username: "files")
            let sftp = SessionProfile(name: "SFTP 服务器", group: "测试", kind: .sftp, host: "sftp.example.invalid", port: 2223, username: "transfer")
            var local = SessionProfile.local; local.group = "测试"; local.name = "本地工作台"
            var config = workspace.configuration
            config.profiles = [ssh, ftp, sftp, local]; config.proxies = [proxy]
            config.sessionLinks.add(profileID: ssh.id, name: "常用服务器", folder: "生产")
            checks["fixtureSaved"] = workspace.saveConfiguration(config)
            let saved = try? Data(contentsOf: workspace.store.url)
            func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
            func items(_ menu: NSMenu) -> [NSMenuItem] {
                menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
            }
            let toolbar = views(workspace.window!.contentView!).first { $0.identifier?.rawValue == "toolbar.quickConnect" } as? NSPopUpButton
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            for (name, menu) in [("toolbar", toolbar?.menu), ("menubar", workspace.quickMenu)] {
                guard let menu else { checks[name + "Exists"] = false; continue }
                let all = items(menu)
                for profile in config.profiles {
                    let item = all.first { $0.title == profile.name }
                    let row = item?.view as? QuickConnectMenuRow
                    checks[name + profile.kind.rawValue + "Row"] = row != nil && item?.representedObject as? UUID == profile.id
                    if let row {
                        row.pasteboard = board
                        let tabs = workspace.tabs.count
                        row.copyButton.performClick(nil)
                        checks[name + profile.kind.rawValue + "Copy"] = board.string(forType: .string) == item?.toolTip
                            && workspace.tabs.count == tabs && row.copyButton.toolTip == "已复制连接信息"
                    }
                }
                if let item = all.first(where: { $0.title == "常用服务器" }), let row = item.view as? QuickConnectMenuRow {
                    let detail = row.details
                    checks[name + "AliasDetails"] = detail.contains("源会话：生产服务器") && detail.contains("/Links/生产")
                        && detail.contains("host.example.invalid") && detail.contains("端口：2222") && detail.contains("用户名：ops")
                        && detail.contains("jump@[2001:db8::1]:2200") && detail.contains("/srv/project")
                    checks[name + "PrivatePathsExcluded"] = !detail.contains("PRIVATE_KEY_PATH")
                    row.pasteboard = board; board.clearContents(); board.setString("untouched", forType: .string)
                    row.canCopy = { false }; row.copyButton.performClick(nil)
                    checks[name + "LockedCopyDenied"] = board.string(forType: .string) == "untouched"
                    row.canCopy = { true }
                    let probe = ActionProbe(); item.target = probe; item.action = #selector(ActionProbe.connect(_:))
                    row.copyButton.performClick(nil)
                    checks[name + "CopyNeverConnects"] = probe.calls == 0
                    row.subviews.compactMap { $0 as? NSButton }.first { $0 !== row.copyButton }?.performClick(nil)
                    checks[name + "BodyConnectsExactlyOnce"] = probe.calls == 1
                    _ = NSApp.sendAction(item.action!, to: item.target, from: item)
                    checks[name + "NativeMenuActionRetained"] = probe.calls == 2
                }
            }
            var sensitive = ssh
            sensitive.encryptedPassword = .init(salt: "SECRET_SALT", ciphertext: "SECRET_CIPHERTEXT",
                                                identity: .init(host: ssh.host, user: ssh.username, port: ssh.port))
            let safe = QuickConnectDetails.connection(sensitive, configuration: config, globalProxy: .success(.init()))
            checks["CredentialEnvelopeExcluded"] = !safe.contains("SECRET_") && !safe.contains("PRIVATE_KEY_PATH")
            let localText = QuickConnectDetails.connection(local, configuration: config, globalProxy: .success(.init()))
            checks["LocalHasNoFakeRemoteEndpoint"] = localText.contains("本地 Shell") && !localText.contains("端口：") && !localText.contains("主机：")
            var broken = ssh; broken.proxyID = UUID()
            checks["BrokenProxyNotReportedAsDirect"] = QuickConnectDetails.connection(broken, configuration: config, globalProxy: .success(.init())).contains("配置不可用")
            var global = GlobalProxySettings(); global.enabled = true; global.proxyID = proxy.id
            checks["GlobalProxyIncluded"] = QuickConnectDetails.connection(sftp, configuration: config, globalProxy: .success(global)).contains("全局代理：已计入连接路线")
            checks["ViewingAndCopyingDoNotRewriteConfiguration"] = saved != nil && saved == (try? Data(contentsOf: workspace.store.url))
            if let path = ProcessInfo.processInfo.environment["OSHELL_QUICK_DETAILS_OUTPUT"] {
                try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path))
            }
            workspace.shutdown(); NSApp.terminate(nil)
        }
    }
}
