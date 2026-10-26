// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import Darwin
import OShellCore

/// OpenSSH needs a local UTF-8 LC_CTYPE to render authentication banners. Apply
/// SendEnv removals AFTER user/system config, without editing either file.
final class SSHClientLocale {
    let arguments: [String]
    private let directory: URL
    static func environment(_ inherited: [String: String]) -> [String: String] {
        var value = SSHEnvironment.remoteClient(inherited)
        value["LC_CTYPE"] = "UTF-8" // Supported by macOS.
        return value
    }
    init(arguments: [String], currentDirectory: String = FileManager.default.currentDirectoryPath) throws {
        var remaining = arguments, explicit: String?, index = 0
        let operands = Set("BbcDEeFIiJLlmOoPpQRSWwX".map { "-" + String($0) })
        while index < remaining.count {
            let argument = remaining[index]
            if argument == "--" || !argument.hasPrefix("-") { break }
            if argument == "-F" {
                guard index + 1 < remaining.count else { throw ModelError.invalid("SSH -F 缺少配置文件路径。") }
                explicit = remaining[index + 1]; remaining.removeSubrange(index...index + 1); continue
            }
            if argument.hasPrefix("-F"), argument.count > 2 { explicit = String(argument.dropFirst(2)); remaining.remove(at: index); continue }
            index += operands.contains(argument) ? 2 : 1
        }
        var pattern = Array("/tmp/oshell-locale-\(geteuid())-XXXXXX".utf8CString)
        guard mkdtemp(&pattern) != nil else { throw ModelError.invalid("无法创建 SSH 本机编码配置。") }
        directory = URL(fileURLWithPath: String(cString: pattern))
        do {
            func include(_ path: String) throws -> String {
                guard !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), !path.contains("%"), !path.contains("${"), !path.contains(where: { "*?[".contains($0) }) else { throw ModelError.invalid("SSH 配置文件路径包含不支持的字符。") }
                return "Include \"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"\n"
            }
            var content = ""
            if let explicit {
                if explicit != "none" && explicit != "/dev/null" {
                    let path = NSString(string: explicit).expandingTildeInPath
                    let absolute = path.hasPrefix("/") ? path : URL(fileURLWithPath: currentDirectory).appendingPathComponent(path).path
                    guard FileManager.default.isReadableFile(atPath: absolute) else { throw ModelError.invalid("无法读取指定的 SSH 配置文件。") }
                    content += try include(absolute)
                }
            } else {
                let userConfig = NSHomeDirectory() + "/.ssh/config"
                var attributes = stat()
                if stat(userConfig, &attributes) == 0 {
                    guard (attributes.st_uid == getuid() || attributes.st_uid == 0), attributes.st_mode & 0o022 == 0 else { throw ModelError.invalid("用户 SSH 配置权限不安全；请检查 ~/.ssh/config 的所有者和写入权限。") }
                }
                content += try include(userConfig)
                content += try include("/etc/ssh/ssh_config")
            }
            content += "\nHost *\n    SendEnv -LANG -LANGUAGE -LC_*\n"
            let config = directory.appendingPathComponent("config")
            try PrivateFile.write(Data(content.utf8), to: config)
            self.arguments = ["-F", config.path] + remaining
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
