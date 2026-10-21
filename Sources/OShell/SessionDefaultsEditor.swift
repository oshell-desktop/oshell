// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class SessionDefaultsEditor {
    let alert = PopupAlert()
    let sshPort = NSTextField(), sshUser = NSTextField(), key = NSTextField(), sshDirectory = NSTextField()
    let ftpPort = NSTextField(), ftpUser = NSTextField(), ftpDirectory = NSTextField()
    let legacy = NSButton(checkboxWithTitle: "兼容旧版 SSH 服务（SSH / SFTP）", target: nil, action: nil)
    let quick = NSButton(checkboxWithTitle: "显示在快捷连接菜单", target: nil, action: nil)
    let alive = NSButton(checkboxWithTitle: "发送 SSH 保持活动消息", target: nil, action: nil)
    let interval = NSTextField(), missed = NSTextField()
    let tcp = NSButton(checkboxWithTitle: "启用 TCP KeepAlive", target: nil, action: nil)
    let idle = NSButton(checkboxWithTitle: "终端空闲时发送字符串（仅 SSH 终端）", target: nil, action: nil)
    let idleInterval = NSTextField(), idleText = NSTextField()
    init(_ value: SessionDefaults) {
        alert.messageText = "会话默认属性"
        alert.informativeText = "仅用于以后新建的会话配置，不会更新已有、复制或导入的会话，也不会修改当前连接。已有会话需在属性的“保持活动”页点击“使用全局默认”并保存；SSH 协议保活需重新连接后生效。"
        alert.addButton(withTitle: "保存默认值"); alert.addButton(withTitle: "取消")
        sshPort.identifier = .init("defaults.sshPort"); interval.identifier = .init("defaults.aliveInterval")
        let tabs = NSTabView(); tabs.frame = NSRect(x: 0, y: 0, width: 620, height: 370)
        func page(_ title: String, _ rows: [(String, NSView)], note: String) {
            let view = NSView(), grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
            grid.column(at: 0).width = 142; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .fill
            grid.columnSpacing = 14; grid.rowSpacing = 12
            let label = NSTextField(wrappingLabelWithString: note); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            for control in [grid, label] { control.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(control) }
            NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18), grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18), label.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16), label.leadingAnchor.constraint(equalTo: grid.leadingAnchor), label.trailingAnchor.constraint(equalTo: grid.trailingAnchor)])
            let item = NSTabViewItem(identifier: title); item.label = title; item.view = view; tabs.addTabViewItem(item)
        }
        sshPort.stringValue = String(value.sshPort); sshUser.stringValue = value.sshUsername
        key.stringValue = value.identityFile; sshDirectory.stringValue = value.sshDirectory
        ftpPort.stringValue = String(value.ftpPort); ftpUser.stringValue = value.ftpUsername; ftpDirectory.stringValue = value.ftpDirectory
        legacy.state = value.legacySSH ? .on : .off; quick.state = value.quickConnect ? .on : .off
        alive.state = value.keepAlive.enabled ? .on : .off; interval.stringValue = String(value.keepAlive.interval); missed.stringValue = String(value.keepAlive.maxMissed)
        tcp.state = value.keepAlive.tcp ? .on : .off; idle.state = value.keepAlive.idleEnabled ? .on : .off
        idleInterval.stringValue = String(value.keepAlive.idleInterval); idleText.stringValue = value.keepAlive.idleText
        page("SSH / SFTP", [("端口", sshPort), ("用户名", sshUser), ("私钥路径", key), ("文件初始目录", sshDirectory), ("", legacy), ("", quick)], note: "用户名可留空使用系统 SSH 默认用户。快捷连接选项也用于新 FTP 会话。主机、密码、代理和隧道按会话单独配置，可通过复制会话复用。")
        page("保持活动", [("", alive), ("间隔（秒）", interval), ("最大未响应次数", missed), ("", tcp), ("", idle), ("空闲间隔（秒）", idleInterval), ("发送字符串", idleText)], note: "SSH / SFTP 协议保活不显示在终端中；当前 SSH 连接的空闲字符串可在标签右键“当前会话属性…”即时应用。字符串支持 \\n、\\r、\\t、\\e、\\\\；可以执行命令，输入、输出或文件传输期间不发送。")
        page("FTP", [("端口", ftpPort), ("用户名", ftpUser), ("文件初始目录", ftpDirectory)], note: "普通 FTP 不应用 SSH 保持活动、私钥或旧版兼容设置。")
        alert.accessoryView = tabs; alert.window.initialFirstResponder = sshPort
    }
    func values() throws -> SessionDefaults {
        var value = SessionDefaults()
        value.sshPort = Int(sshPort.stringValue) ?? 0; value.sshUsername = sshUser.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.identityFile = key.stringValue; value.sshDirectory = sshDirectory.stringValue
        value.ftpPort = Int(ftpPort.stringValue) ?? 0; value.ftpUsername = ftpUser.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); value.ftpDirectory = ftpDirectory.stringValue
        value.legacySSH = legacy.state == .on; value.quickConnect = quick.state == .on
        value.keepAlive.enabled = alive.state == .on; value.keepAlive.interval = Int(interval.stringValue) ?? 0; value.keepAlive.maxMissed = Int(missed.stringValue) ?? 0
        value.keepAlive.tcp = tcp.state == .on; value.keepAlive.idleEnabled = idle.state == .on
        value.keepAlive.idleInterval = Int(idleInterval.stringValue) ?? 0; value.keepAlive.idleText = idleText.stringValue
        try value.validate(); return value
    }
    func run() -> SessionDefaults? {
        while alert.runModal() == .alertFirstButtonReturn {
            do { return try values() } catch { Dialogs.message(error.localizedDescription) }
        }
        return nil
    }
}
