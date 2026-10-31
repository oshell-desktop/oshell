// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import SwiftTerm
import OShellCore

/// A fresh PTY per tool; it never reuses the original SSH process or credentials.
final class LocalToolProcess: LocalProcessDelegate {
    let command: LocalToolCommand
    private var process: LocalProcess!
    private var sshClientLocale: SSHClientLocale?
    private var drainTimer: DispatchSourceTimer?
    private(set) var exited = false
    private var stopped = false
    private var exitCode: Int32?
    private var size = winsize()
    var onData: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var deliveryPaused: Bool {
        get { process.deliveryPaused }
        set { process.deliveryPaused = newValue }
    }
    var pid: pid_t { process?.shellPid ?? 0 }
    // Interactive tools and tools that can prompt for secrets stay in this pane.
    var permitsManagedInput: Bool { command.permitsManagedInput }
    init(command: LocalToolCommand, size: winsize) {
        self.command = command; self.size = size; process = LocalProcess(delegate: self)
    }
    func start() throws {
        let executable = try command.executable()
        var environment = ProcessInfo.processInfo.environment
        for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "OSHELL_AUTH_SOCKET", "OSHELL_AUTH_TOKEN"] { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"; environment["LC_CTYPE"] = "UTF-8"
        var arguments = command.arguments
        if command.name == "ssh" {
            let locale = try SSHClientLocale(arguments: arguments, currentDirectory: NSHomeDirectory()); sshClientLocale = locale; arguments = locale.arguments
            environment = SSHClientLocale.environment(environment)
        }
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/sbin"
        process.startProcess(executable: executable, args: arguments, environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: NSHomeDirectory())
        if !exited && process.shellPid == 0 { throw ModelError.invalid("无法启动本机工具 \(command.name)。") }
    }
    func send(_ bytes: ArraySlice<UInt8>) { guard !stopped, !exited else { return }; process.send(data: bytes) }
    func resize(_ next: winsize) {
        guard next.ws_row != size.ws_row || next.ws_col != size.ws_col || next.ws_xpixel != size.ws_xpixel || next.ws_ypixel != size.ws_ypixel else { return }
        size = next
        if process.childfd >= 0 { var value = size; _ = ioctl(process.childfd, TIOCSWINSZ, &value) }
    }
    func getWindowSize() -> winsize { size }
    func dataReceived(slice: ArraySlice<UInt8>) { if !stopped { onData?(Data(slice)) } }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard !stopped, !exited else { return }; exited = true; self.exitCode = exitCode
        let timer = DispatchSource.makeTimerSource(queue: .main); drainTimer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.process.hasDrainedOutput else { return }
            self.drainTimer?.cancel(); self.drainTimer = nil
            let completion = self.onExit; self.onExit = nil; self.onData = nil; self.stopped = true
            self.process.terminate(); completion?(self.exitCode)
        }
        timer.resume()
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        drainTimer?.cancel(); drainTimer = nil; onExit = nil; onData = nil
        // Signal only the foreground group attached to this dedicated PTY.
        if process.childfd >= 0 {
            let group = tcgetpgrp(process.childfd)
            if group > 0 && group != getpgrp() { _ = kill(-group, SIGHUP) }
        }
        process.terminate()
    }
    deinit { stop() }
}
