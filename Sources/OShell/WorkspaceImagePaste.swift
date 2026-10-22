// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

private final class ClipboardUploadState {
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private var progress: (UInt64, UInt64)?
    func finish(_ result: Result<String, Error>) { lock.lock(); self.result = result; lock.unlock() }
    func update(_ sent: UInt64, _ total: UInt64) { lock.lock(); progress = (sent, total); lock.unlock() }
    func snapshot() -> (Result<String, Error>?, (UInt64, UInt64)?) {
        lock.lock(); defer { lock.unlock() }; return (result, progress)
    }
}

extension WorkspaceController {
    func pasteImage(_ image: TerminalClipboardImage, from source: TerminalPane) {
        guard isSecurityUnlocked, NSApp.modalWindow == nil, inputPanes.contains(where: { $0 === source }),
              !source.isShutdown, !source.isTransferring else { return }
        let remote = !source.ended && source.profile.kind.usesSSH
        let group = remote ? source.sshConnectionGroup : nil
        let local = !remote && source.usesPTYInput && !["ssh", "telnet"].contains(source.localToolName ?? "")
            && (source.profile.kind == .local || source.ended)
        guard (remote && source.acceptsManagedInput && group?.isAvailable == true)
                || (local && (source.acceptsManagedInput || source.blocksManagedToolInput)) else {
            Dialogs.message("请在本地终端或已连接的 SSH 会话中粘贴图片。通过终端内另行运行 ssh/telnet 的连接无法自动上传，请改用 OShell 会话管理建立 SSH 连接。"); return
        }
        let pid = source.terminal.process.shellPid, toolPID = source.localToolPID
        let hostname = source.remoteHostname, address = source.remoteAddress
        func stillCurrent() -> Bool {
            self.inputPanes.contains(where: { $0 === source }) && !source.isShutdown && !source.isTransferring
                && source.usesPTYInput && source.terminal.process.shellPid == pid && source.localToolPID == toolPID
                && source.remoteHostname == hostname && source.remoteAddress == address
                && (remote ? (!source.ended && source.sshConnectionGroup === group && group?.isAvailable == true) : local)
        }
        let alert = PopupAlert(); alert.messageText = "粘贴图片"
        let size = ByteCountFormatter.string(fromByteCount: Int64(image.png.count), countStyle: .file)
        alert.informativeText = "PNG · \(image.width) × \(image.height) · \(size)\n" + (remote
            ? "上传到 \(source.profile.name)（\(source.profile.host)）后粘贴远端路径。请确认程序运行在此 SSH 主机上，且能访问目标目录；容器或再次 SSH 登录的环境可能有不同文件系统。图片保留在独立的远端临时目录，用完可删除。"
            : "保存到本机私有缓存并粘贴文件路径，供 Codex、OpenCode 等程序读取。图片保留 7 天，之后在下次图片粘贴时清理；若程序在容器或远端运行，需先将图片放到它能访问的位置。")
            + "\n仅粘贴到当前终端，不广播、不自动回车。"
        alert.addButton(withTitle: remote ? "上传图片并粘贴路径" : "保存图片并粘贴路径")
        alert.addButton(withTitle: "取消")
        let directory = NSTextField(string: "/tmp")
        if remote {
            directory.identifier = .init("paste.image.remoteDirectory")
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 48))
            let label = NSTextField(labelWithString: "远端存放目录（可改为项目目录）")
            label.frame = NSRect(x: 0, y: 28, width: 400, height: 18)
            directory.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
            box.addSubview(label); box.addSubview(directory); alert.accessoryView = box
        }
        guard alert.runModal() == .alertFirstButtonReturn, stillCurrent() else { return }
        var localFile: URL?
        do {
            let file = try TerminalClipboardFiles.save(image); localFile = file
            let path: String
            if remote, let group {
                guard !directory.stringValue.isEmpty else { throw ModelError.invalid("请输入远端存放目录。") }
                try RemotePath.validate(directory.stringValue)
                let backend = try SFTPBackend(profile: source.profile, knownHosts: knownHostsURL, connectionGroup: group)
                defer { backend.cancel() }
                guard let uploaded = uploadClipboardImage(file, backend: backend, directory: directory.stringValue, stillCurrent: stillCurrent) else {
                    try? FileManager.default.removeItem(at: file); return
                }
                path = uploaded
            } else { path = file.path }
            guard stillCurrent() else { throw ModelError.invalid("目标会话已改变或断开，未粘贴图片路径。") }
            try deliverImagePath(path, to: source)
            if remote { try? FileManager.default.removeItem(at: file) }
        } catch {
            if let localFile { try? FileManager.default.removeItem(at: localFile) }
            Dialogs.message("图片粘贴失败：" + error.localizedDescription)
        }
    }

    /// Image paths are deliberately not routed through the broadcast text-paste path.
    func deliverImagePath(_ path: String, to source: TerminalPane) throws {
        guard inputPanes.contains(where: { $0 === source }), !source.isShutdown, !source.isTransferring, source.usesPTYInput,
              source.acceptsManagedInput || source.blocksManagedToolInput else { throw ModelError.invalid("目标终端已不可输入，未粘贴图片路径。") }
        let escaped = try TerminalClipboardFiles.pastedPath(path)
        let bytes = InputText.bytes(escaped, bracketed: source.terminal.getTerminal().bracketedPasteMode)
        source.terminal.ensureCaretIsVisible()
        if source.blocksManagedToolInput { source.handleEndedInput(bytes[...]) }
        else { source.sendManaged(bytes) }
    }

    private func uploadClipboardImage(_ file: URL, backend: SFTPBackend, directory: String, stillCurrent: @escaping () -> Bool) -> String? {
        let alert = PopupAlert(); alert.messageText = "正在上传图片"
        alert.informativeText = "通过当前已认证的 SSH 连接上传；完成后粘贴路径。"
        alert.addButton(withTitle: "取消")
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 360, height: 18))
        progress.isIndeterminate = true; progress.startAnimation(nil); alert.accessoryView = progress
        let state = ClipboardUploadState()
        var lostTarget = false
        let base = directory
        DispatchQueue.global(qos: .userInitiated).async {
            state.finish(Result {
                try backend.connect()
                return try backend.uploadClipboardImage(file, in: base) { state.update($0, $1) }
            })
        }
        // A modal loop may itself be entered from a main-queue callback. Use a
        // lock-protected worker result polled by a modal-mode timer, so completion
        // never waits for the still-running main-queue callback to return.
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            let (result, amount) = state.snapshot()
            if let (sent, total) = amount {
                progress.isIndeterminate = false; progress.maxValue = Double(max(total, 1)); progress.doubleValue = Double(sent)
            }
            if !stillCurrent(), !lostTarget { lostTarget = true; backend.cancel() }
            if NSApp.modalWindow === alert.window, result != nil || lostTarget { NSApp.stopModal(withCode: .OK) }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate(); backend.cancel()
        guard !lostTarget else { Dialogs.message("目标会话已改变或断开，图片路径未粘贴。"); return nil }
        guard response == .OK, let result = state.snapshot().0 else { return nil }
        switch result {
        case .success(let path): return path
        case .failure(let error): Dialogs.message("上传失败，未粘贴路径：" + error.localizedDescription); return nil
        }
    }
}
