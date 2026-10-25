// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

enum SSHClientLocaleTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let config = root.appendingPathComponent("config")
            try Data("Host fixture\n HostName 127.0.0.1\n Port 2222\n User fixture-user\n SendEnv LANG LC_* CUSTOM_TEST\n".utf8).write(to: config)
            var wrapper: SSHClientLocale? = try SSHClientLocale(arguments: ["-F", config.path, "-o", "BatchMode=yes", "fixture"])
            let path = wrapper!.arguments[1]
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); task.arguments = ["-G"] + wrapper!.arguments
            task.environment = SSHClientLocale.environment(["PATH": "/usr/bin:/bin", "LANG": "bad-locale", "LC_ALL": "C", "CUSTOM_TEST": "fixture"])
            let output = Pipe(); task.standardOutput = output; task.standardError = FileHandle.nullDevice
            try task.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            checks["localeConfigKeepsHostOptions"] = task.terminationStatus == 0 && text.contains("hostname 127.0.0.1") && text.contains("port 2222") && text.contains("user fixture-user")
            checks["localeConfigRemovesOnlyLocaleForwarding"] = !text.contains("sendenv LANG") && !text.contains("sendenv LC_") && text.contains("sendenv CUSTOM_TEST")
            checks["localeClientUsesUTF8OnlyLocally"] = task.environment?["LC_CTYPE"] == "UTF-8" && task.environment?["LANG"] == nil && task.environment?["LC_ALL"] == nil
            checks["localeConfigPrivate"] = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            wrapper = nil; checks["localeConfigCleanedOnRelease"] = !FileManager.default.fileExists(atPath: path)
            let relative = try SSHClientLocale(arguments: ["-F", "config", "fixture"], currentDirectory: root.path)
            checks["localeRelativeConfigUsesClientWorkingDirectory"] = try String(contentsOfFile: relative.arguments[1], encoding: .utf8).contains(config.path)
            let disabled = try SSHClientLocale(arguments: ["-F", "/dev/null", "fixture"])
            checks["localeDisabledConfigDoesNotIncludeDevice"] = try !String(contentsOfFile: disabled.arguments[1], encoding: .utf8).contains("Include")
            let combined = try SSHClientLocale(arguments: ["-F" + config.path, "--", "fixture"])
            checks["localeCombinedConfigFlagHandled"] = combined.arguments.suffix(2) == ["--", "fixture"]
            do { _ = try SSHClientLocale(arguments: ["-F", root.appendingPathComponent("missing").path, "fixture"]); checks["localeMissingExplicitConfigFailsClosed"] = false }
            catch { checks["localeMissingExplicitConfigFailsClosed"] = true }
        } catch { checks["localeSetup"] = false; print("SSH locale fixture:", error.localizedDescription) }
        return checks
    }
}
