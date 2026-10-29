// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import OShellCore

/// Parses progress incrementally. Neither filenames nor a large file list are retained.
final class RsyncProgressParser {
    private var line = Data(), dropping = false
    private var completed: UInt64 = 0, current: UInt64 = 0
    private let progress: (UInt64, Double) -> Void
    init(progress: @escaping (UInt64, Double) -> Void) { self.progress = progress }
    private func sum(_ a: UInt64, _ b: UInt64) -> UInt64 { let (value, overflow) = a.addingReportingOverflow(b); return overflow ? UInt64.max : value }
    func consume(_ bytes: Data) {
        for byte in bytes {
            if byte == 10 || byte == 13 {
                if !dropping { parse(String(decoding: line, as: UTF8.self)) }
                line.removeAll(keepingCapacity: true); dropping = false
            } else if line.count < 4096 && !dropping { line.append(byte) }
            else { dropping = true; line.removeAll(keepingCapacity: true) }
        }
    }
    private func parse(_ text: String) {
        if text.hasPrefix("OSHELL_RSYNC_FILE:") {
            completed = sum(completed, current); current = 0; return
        }
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2, fields[1].hasSuffix("%"),
              let bytes = UInt64(fields[0].replacingOccurrences(of: ",", with: "")),
              let percent = Double(fields[1].dropLast()), percent.isFinite, (0...100).contains(percent) else { return }
        current = max(current, bytes); progress(sum(completed, current), percent)
    }
}

/// System rsync over SSH. A private launcher preserves argument boundaries for
/// rsync's -e parser; the launcher never contains a password or an auth token.
final class RsyncTransfer {
    private let profile: SessionProfile, knownHosts: URL, lease: SSHConnectionLease?
    private let oneTimePassword: String?, rateLimit: Int
    private let lock = NSLock()
    private var process: FileProcess?, broker: AuthBroker?, cancelled = false
    init(profile: SessionProfile, knownHosts: URL, oneTimePassword: String? = nil, connectionGroup: SSHConnectionGroup? = nil, rateLimit: Int = 0) throws {
        guard profile.kind.usesSSH else { throw ModelError.invalid("rsync 仅用于 SSH / SFTP 会话。") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync") else { throw ModelError.invalid("本机缺少 /usr/bin/rsync。") }
        self.profile = profile; self.knownHosts = knownHosts; self.rateLimit = min(FileTransferRateLimiter.maximum, max(0, rateLimit))
        lease = try connectionGroup.map { try SSHConnectionLease(group: $0, profile: profile) }
        self.oneTimePassword = connectionGroup == nil ? oneTimePassword : nil
    }
    func run(local: URL, remote: String, upload: Bool, directory: Bool, progress: @escaping (UInt64, Double) -> Void = { _,_ in }) throws {
        try RemotePath.validate(remote)
        guard !remote.isEmpty, local.isFileURL else { throw ModelError.invalid("请指定有效的本地和远程路径。") }
        var info = stat()
        if lstat(local.path, &info) == 0 {
            let type = info.st_mode & S_IFMT
            guard type != S_IFLNK, directory ? type == S_IFDIR : type == S_IFREG else { throw ModelError.invalid("本地目标类型不匹配；rsync 入口不接受符号链接或特殊文件。") }
        } else if upload { throw ModelError.invalid("本地源文件或目录不存在。") }
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { throw ModelError.invalid("操作已取消。") }
        let auth: AuthBroker?
        if lease != nil { auth = nil }
        else { auth = try Thread.isMainThread ? AuthBroker(profile: profile, oneTimePassword: oneTimePassword) : DispatchQueue.main.sync { try AuthBroker(profile: profile, oneTimePassword: oneTimePassword) } }
        lock.lock(); broker = auth; lock.unlock()
        defer {
            lock.lock(); process = nil; broker = nil; lock.unlock()
            DispatchQueue.main.async { auth?.stop() }
        }
        let ssh = (try lease?.group.arguments(for: profile, clone: true) ?? []) + (try FileSSH.arguments(profile, knownHosts: knownHosts, reusingConnection: lease != nil))
        let locale = try SSHClientLocale(arguments: ssh)
        var pattern = Array("/tmp/oshell-rsync-\(geteuid())-XXXXXX".utf8CString)
        guard mkdtemp(&pattern) != nil else { throw ModelError.invalid("无法创建 rsync 私有运行目录。") }
        let temporary = URL(fileURLWithPath: String(cString: pattern))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let launcher = temporary.appendingPathComponent("ssh")
        let script = "#!/bin/sh\nexec /usr/bin/ssh " + locale.arguments.map(ConnectionValidation.quote).joined(separator: " ") + " \"$@\"\n"
        try PrivateFile.write(Data(script.utf8), to: launcher)
        guard chmod(launcher.path, 0o700) == 0 else { throw ModelError.invalid("无法设置 rsync 启动器权限。") }
        // macOS 15's rsync and newer Apple openrsync share these options.
        // Keep destination-only files, preserve times and safe relative symlinks,
        // and use temporary files instead of --inplace or destructive mirroring.
        var args = ["-rlt", "--safe-links", "--partial-dir=.oshell-rsync-partial", "--progress", "--out-format=OSHELL_RSYNC_FILE:%l", "--timeout=60", "-e", launcher.path]
        if rateLimit > 0 { args.append("--bwlimit=\(max(1, (rateLimit + 1023) / 1024))") }
        let remoteBase = remote.hasPrefix("/") || remote.hasPrefix("./") ? remote : "./" + remote
        let remotePath = directory ? RemotePath.join(remoteBase, "") : remoteBase
        let localPath = directory ? local.path + "/" : local.path
        let endpoint = ConnectionValidation.bracket(profile.host) + ":" + ConnectionValidation.quote(remotePath)
        args += ["--"] + (upload ? [localPath, endpoint] : [endpoint, localPath])
        var environment = SSHClientLocale.environment(FileSSH.environment(auth))
        for key in Array(environment.keys) where key.hasPrefix("RSYNC_") { environment.removeValue(forKey: key) }
        // We quote remote paths explicitly for the legacy Apple clients as well
        // as modern upstream clients. Never let inherited flags change quoting.
        environment["RSYNC_OLD_ARGS"] = "1"; environment["RSYNC_PROTECT_ARGS"] = "0"
        let task = FileProcess(executable: "/usr/bin/rsync", arguments: args, environment: environment)
        lock.lock(); guard !cancelled else { lock.unlock(); throw ModelError.invalid("操作已取消。") }; process = task; lock.unlock()
        let parser = RsyncProgressParser(progress: progress)
        do {
            try task.start(); task.closeInput()
            _ = try task.outputToEnd(consume: parser.consume)
        } catch {
            task.cancel()
            // Run on the file worker: let rsync close its SSH channel before a
            // queued retry can reuse the same partial directory. Never wait on UI.
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while task.task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            let text = error.localizedDescription
            if text.contains("rsync"), text.contains("not found") || text.contains("command not found") {
                throw ModelError.invalid("远端没有可用的 rsync，请先安装后重试。\n" + text)
            }
            throw error
        }
        withExtendedLifetime(locale) {}
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = process, auth = broker; lock.unlock()
        task?.cancel(); lease?.release(); DispatchQueue.main.async { auth?.stop() }
    }
    deinit { process?.cancel(); lease?.release(); let auth = broker; DispatchQueue.main.async { auth?.stop() } }
}
