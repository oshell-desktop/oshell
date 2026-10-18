// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.dropFirst().contains("--help") {
    print("OShell-ZOC: /DEV:SSH /CONNECT:user:password@host:port /EMU:Xterm /TITLE:title\n支持 /SSH、/SSHUSER、/SSHPASSWORD、/SSHKEY 及 -参数 值。只兼容连接启动，不执行 ZOC 脚本。 Incremental source-change verification.")
    exit(0)
}
do {
    let request: ZOCLaunchRequest
    do {
        defer {
            // USM supplies argv credentials. Shorten their visibility in process listings.
            let argv = CommandLine.unsafeArgv
            for index in 1..<Int(CommandLine.argc) { if let value = argv[index] { memset(value, 0, strlen(value)) } }
        }
        request = try ZOCLaunchRequest.parse(Array(CommandLine.arguments.dropFirst()))
    }
    try ExternalLaunchClient.send(ExternalLaunchRequest(terminal: request))
    exit(0)
} catch {
    // Never include the raw command line, endpoint or credentials in error logs.
    let message = (error as? ModelError)?.localizedDescription ?? "OShell ZOC 启动失败，请检查应用版本及本机启动通道。"
    FileHandle.standardError.write(Data((message + "\n").utf8))
    if ProcessInfo.processInfo.environment["OSHELL_LAUNCH_NO_UI"] != "1" {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "OShell 启动失败"; alert.informativeText = message
        let close = alert.addButton(withTitle: "关闭"); close.keyEquivalent = "\u{1b}"; close.keyEquivalentModifierMask = []
        alert.runModal()
    }
    exit(1)
}
