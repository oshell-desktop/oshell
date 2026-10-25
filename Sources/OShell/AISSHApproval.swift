// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

/// Authority is chosen in the client, never by model output or terminal text.
enum AIPermissionMode: String, Codable, CaseIterable {
    case ask, assist, fullAccess
    var title: String {
        switch self { case .ask: return "请求批准"; case .assist: return "帮我批准"; case .fullAccess: return "完全访问" }
    }
    var explanation: String {
        switch self {
        case .ask: return "每条命令执行前请求批准"
        case .assist: return "自动批准查询；修改、创建、删除和服务变更需批准"
        case .fullAccess: return "自动执行通过安全校验的操作；危险命令拒绝"
        }
    }
    func automaticallyAllows(_ query: AIReadOnlyQuery) -> Bool {
        guard (try? query.validateExecution()) != nil else { return false }
        switch self { case .ask: return false; case .assist: return !query.isMutation; case .fullAccess: return true }
    }
}

enum AISSHApprovalDecision { case deny, once, readOnlyForTask }

final class AISSHExecutionPermit {
    private let operation: AIReadOnlyQuery
    private let valid: () -> Bool
    private var consumed = false
    init(operation: AIReadOnlyQuery, valid: @escaping () -> Bool) {
        self.operation = operation; self.valid = valid
    }
    func consume(for operation: AIReadOnlyQuery) throws {
        guard !consumed, self.operation == operation, valid() else {
            throw ModelError.invalid("SSH 操作审批已失效，未执行。")
        }
        try operation.validateExecution()
        consumed = true
    }
}

/// A deliberately bounded argv interface, never an arbitrary shell evaluator.
/// Unsupported commands, wrappers, expansion and compound shell syntax fail closed.
enum AISSHCommandPolicy {
    static func validate(_ argv: [String]) throws {
        func reject(_ reason: String) throws { throw ModelError.invalid("已拒绝 SSH 操作：" + reason) }
        guard !argv.isEmpty, argv.count <= 32, argv.joined().utf8.count <= 16384,
              argv.enumerated().allSatisfy({ index, value in
                  !value.unicodeScalars.contains { scalar in
                      CharacterSet.controlCharacters.contains(scalar) && !(argv.first == "write-file" && index == 2 && [9, 10, 13].contains(Int(scalar.value)))
                  }
              }) else {
            try reject("命令参数无效。"); return
        }
        let name = (argv[0] as NSString).lastPathComponent
        let forbidden: Set<String> = ["reboot", "shutdown", "poweroff", "halt", "init", "telinit", "mkfs", "mkswap", "dd", "wipefs", "fdisk", "sfdisk", "parted", "shred"]
        if forbidden.contains(name) || name.hasPrefix("mkfs.") { try reject("极端危险命令 \(name) 不允许执行。"); return }
        guard argv[0] == name || ["/bin/", "/usr/bin/", "/sbin/", "/usr/sbin/"].contains(where: { argv[0] == $0 + name }) else {
            try reject("不支持自定义可执行文件路径。"); return
        }
        if name == "systemctl" {
            guard argv.count == 3, ["start", "stop", "restart", "reload"].contains(argv[1]), AIReadOnlyQuery.validUnit(argv[2]),
                  !["reboot", "shutdown", "poweroff", "halt", "kexec", "exit", "soft-reboot", "suspend", "hibernate", "hybrid-sleep"].contains(where: { argv[2] == $0 + ".service" || argv[2] == "systemd-" + $0 + ".service" }) else {
                try reject("仅支持审批具体 service 的 start/stop/restart/reload；重启或关闭整机等操作被禁止。"); return
            }
            return
        }
        if ["echo", "printf"].contains(name) { return }
        let allowedOptions: [String: Set<String>] = [
            "mkdir": ["-p", "--"], "touch": ["--"], "rm": ["-f", "-r", "-R", "-rf", "-fr", "--"],
            "cp": ["-f", "-n", "-p", "-r", "-R", "--"], "mv": ["-f", "-n", "--"],
            "chmod": ["--"], "chown": ["--"], "write-file": []
        ]
        guard let options = allowedOptions[name] else { try reject("当前不支持此命令的安全执行；不能通过 Shell、脚本解释器、sudo 或其他包装器绕过审批。"); return }
        var operands = Array(argv.dropFirst()), positional = false, paths = [String]()
        while !operands.isEmpty {
            let value = operands.removeFirst()
            if !positional && value.hasPrefix("-") {
                guard options.contains(value) else { try reject("不支持的命令选项。"); return }
                if value == "--" { positional = true }
            } else { positional = true; paths.append(value) }
        }
        if name == "chmod" || name == "chown" {
            guard let value = paths.first, value.range(of: name == "chmod" ? "^[0-7]{3,4}$" : "^[A-Za-z0-9_][A-Za-z0-9_.:-]*$", options: .regularExpression) != nil else {
                try reject("权限或所有者参数无效。"); return
            }
            paths.removeFirst()
        }
        if name == "write-file" {
            guard argv[0] == "write-file" else { try reject("write-file 只能作为内置操作使用。"); return }
            guard paths.count == 2 else { try reject("write-file 需要绝对路径和文件内容。"); return }
            paths = [paths[0]]
        }
        guard !paths.isEmpty, !["cp", "mv"].contains(name) || paths.count == 2 else { try reject("文件操作参数数量无效。"); return }
        let roots: Set<String> = ["/", "/bin", "/sbin", "/usr", "/etc", "/var", "/home", "/root", "/tmp", "/opt", "/lib", "/lib64", "/boot", "/dev", "/proc", "/sys", "/run", "/mnt", "/media"]
        for path in paths {
            guard AIReadOnlyQuery.validLogPath(path), !path.contains("//"), !roots.contains(path),
                  !path.contains(where: { "*?[]{}~".contains($0) }),
                  !["/dev/", "/proc/", "/sys/", "/boot/"].contains(where: { path.hasPrefix($0) }) else {
                try reject("根目录、系统顶层目录、设备路径或通配批量操作被禁止。"); return
            }
        }
    }
    static func command(_ argv: [String]) throws -> String {
        try validate(argv)
        if argv.first == "write-file" {
            let path = ConnectionValidation.quote(argv[1]), content = ConnectionValidation.quote(argv[2].replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t"))
            return "if test ! -L " + path + " && { test ! -e " + path + " || test -f " + path + "; }; then printf '%b' " + content + " > " + path + "; else false; fi"
        }
        return argv.map(ConnectionValidation.quote).joined(separator: " ")
    }
    /// Used for command-card handoff only. Execution always uses quoted argv.
    static func parse(_ text: String) throws -> [String] {
        var args = [String](), word = "", quote: Character?, started = false
        for c in text {
            if c.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { throw ModelError.invalid("已拒绝多行或控制字符命令。") }
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
                continue
            }
            if c == "'" || c == "\"" { quote = c; started = true }
            else if c == " " { if started { args.append(word); word = ""; started = false } }
            else {
                guard !";|&<>$`\\()".contains(c) else { throw ModelError.invalid("已拒绝复合 Shell、重定向、替换或转义；请使用受支持的结构化操作。") }
                word.append(c); started = true
            }
        }
        guard quote == nil else { throw ModelError.invalid("命令引号未闭合。") }
        if started { args.append(word) }
        try validate(args); return args
    }
}
