// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public struct OpenSSHCapabilities {
    public let major: Int, minor: Int
    public init(version: String) {
        let pattern = try! NSRegularExpression(pattern: #"OpenSSH_(\d+)\.(\d+)"#)
        let ns = version as NSString
        if let match = pattern.firstMatch(in: version, range: NSRange(location: 0, length: ns.length)) {
            major = Int(ns.substring(with: match.range(at: 1))) ?? 0
            minor = Int(ns.substring(with: match.range(at: 2))) ?? 0
        } else { major = 0; minor = 0 }
    }
    public var needsSCPLegacyFlag: Bool { major >= 9 }
    public static let current: OpenSSHCapabilities = {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); task.arguments = ["-V"]
        task.standardOutput = pipe; task.standardError = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            return OpenSSHCapabilities(version: String(decoding: data, as: UTF8.self))
        } catch { return OpenSSHCapabilities(version: "") }
    }()
}
