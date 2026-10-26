// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin
import OShellCore

signal(SIGPIPE, SIG_IGN)
let environment = ProcessInfo.processInfo.environment
if environment["SSH_ASKPASS_PROMPT"] == "none" { exit(0) }
guard let endpoint = environment["OSHELL_AUTH_SOCKET"], let token = environment["OSHELL_AUTH_TOKEN"], CommandLine.arguments.count >= 2 else { exit(1) }
do {
    if CommandLine.arguments[1] == "--session-ready" {
        let result = try AuthIPC.request(socketPath: endpoint, request: AuthRequest(token: token, prompt: "", hint: "oshell-session-ready"))
        exit(result.success ? 0 : 1)
    }
    let result = try AuthIPC.request(socketPath: endpoint, request: AuthRequest(token: token, prompt: CommandLine.arguments[1], hint: environment["SSH_ASKPASS_PROMPT"] ?? "", proxyID: environment["OSHELL_AUTH_PROXY_ID"].flatMap(UUID.init(uuidString:))))
    guard result.success, !result.answer.contains("\0"), !result.answer.contains("\n"), !result.answer.contains("\r") else { exit(1) }
    try FileHandle.standardOutput.write(contentsOf: Data((result.answer + "\n").utf8))
} catch { exit(1) }
