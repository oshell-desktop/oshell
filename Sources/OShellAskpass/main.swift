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
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--session-ready" {
        let result = try AuthIPC.request(socketPath: endpoint, request: AuthRequest(token: token, prompt: CommandLine.arguments[2], hint: "oshell-session-ready"))
        if result.success, let nonce = UUID(uuidString: result.answer) {
            try FileHandle.standardOutput.write(contentsOf: BastionPrompt.terminalStart(nonce))
        }
        exit(result.success ? 0 : 1)
    }
    var request = AuthRequest(token: token, prompt: CommandLine.arguments[1], hint: environment["SSH_ASKPASS_PROMPT"] ?? "", proxyID: environment["OSHELL_AUTH_PROXY_ID"].flatMap(UUID.init(uuidString:)))
    let args = CommandLine.arguments
    if args.count >= 3, args[2] == "--oshell-kbdint" {
        request.keyboardInteractiveHash = ""
        if args.count == 7, let port = Int(args[5]), (1...65535).contains(port) {
            request.keyboardInteractiveHash = args[3]
            request.keyboardInteractiveIdentity = SSHIdentity(host: args[4], user: args[6], port: port)
        }
    }
    let result = try AuthIPC.request(socketPath: endpoint, request: request)
    guard result.success, !result.answer.contains("\0"), !result.answer.contains("\n"), !result.answer.contains("\r") else { exit(1) }
    try FileHandle.standardOutput.write(contentsOf: Data((result.answer + "\n").utf8))
} catch { exit(1) }
