// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// One description for the toolbar, accessibility, and the settings card.
struct SyncStatusPresentation {
    enum Mark { case off, waiting, working, complete, attention, locked, cancelled }
    let enabled: Bool
    let directory: Bool
    var backendName: String { enabled ? (directory ? "iCloud / 自定义目录" : "WebDAV") : "仅本地" }
    let mark: Mark
    let title: String
    let guidance: String
    var color: NSColor {
        switch mark {
        case .working, .waiting: return .systemBlue
        case .complete: return .systemGreen
        case .attention, .locked: return .systemOrange
        case .off, .cancelled: return .secondaryLabelColor
        }
    }
    init(sync: WebDAVSync?) {
        // Read the local target once per presentation, not once per UI field.
        let directory = sync?.directory != nil
        let enabled = directory || sync?.enabled == true
        self.init(enabled: enabled, locked: enabled && PasswordVault.shared.cachedMaster == nil, phase: sync?.phase ?? .idle,
                  directory: directory, manualQueued: sync?.manualQueued == true, failure: sync?.summary.failure?.kind, automatic: sync?.policy.automatic ?? true, autoRetry: sync.map { $0.policy.automatic && $0.policy.retryInterval > 0 } ?? true)
    }
    init(enabled: Bool, locked: Bool = false, phase: WebDAVSync.Phase = .idle, directory: Bool = false, manualQueued: Bool = false, failure: SyncDiagnostics.Failure? = nil, automatic: Bool = true, autoRetry: Bool = true) {
        self.enabled = enabled; self.directory = directory
        if !enabled { mark = .off; title = "未启用同步"; guidance = "请在“设置 → 多设备同步”选择同步方式；配置目前只保存在本机。"; return }
        if locked { mark = .locked; title = "等待解锁主密码"; guidance = "解锁后继续同步；本地修改已保留。"; return }
        switch phase {
        case .idle: mark = .waiting; title = automatic ? "等待检查" : "仅手动同步"; guidance = automatic ? "将比较本机与共享配置；无需保持 SSH 连接。" : "可从头部同步图标打开状态窗口，点击“立即同步”。"
        case .queued:
            mark = .waiting; title = !automatic && !manualQueued ? "等待手动同步" : "等待同步"
            guidance = manualQueued ? "已安排同步：关闭设置后使用已保存配置执行；未应用的修改不会生效。" : "本地修改已保存，等待同步；设置打开时暂停新的检查。"
        case .reading: mark = .working; title = "正在读取共享数据"; guidance = "正在比较两端变化，本地配置仍可使用。"
        case .writing: mark = .working; title = "正在加密并上传"; guidance = "正在安全写入共享配置，请稍候。"
        case .applying: mark = .working; title = "正在应用共享数据"; guidance = "正在更新本机配置，已连接的终端保持运行。"
        case .success:
            mark = .complete; title = directory ? "已与本机同步目录对齐" : "同步完成"
            guidance = directory ? "目录文件已对齐；iCloud 云端上传进度请在 Finder 查看。" : "本机与共享配置已对齐，无需额外操作。"
        case .failed:
            mark = .attention; title = "同步未完成 · 本地数据已保留"
            switch failure {
            case .authentication: guidance = "请检查同步配置中的 WebDAV 账号及密码，应用后重试。"
            case .tls: guidance = "请在同步配置中测试连接，检查或核对服务器证书后重试。"
            case .directoryUnavailable, .cloudDownload, .cloudConflict: guidance = "请在 Finder 检查目录是否可用、文件是否已下载，以及是否有冲突副本。"
            case .remoteDeleted: guidance = "共享文件已被删除；请确认目标数据后重新选择同步位置，不会自动覆盖。"
            case .network, .http: guidance = autoRetry ? "请检查网络或服务端；恢复后会自动重试，也可安排一次手动同步。" : "请检查网络或服务端，修复后手动同步。"
            default: guidance = "请查看错误详情或诊断日志，确认两端主密码与版本兼容后重试。"
            }
        case .conflict: mark = .attention; title = "同步需要确认"; guidance = "请在同步状态窗口点击“立即同步”，继续首次接入或冲突处理；确认前不会覆盖数据。"
        case .cancelled: mark = .cancelled; title = "本次同步已取消"; guidance = automatic ? "本地修改已保留；自动检查仍启用，也可重新安排同步。" : "本地修改已保留，可手动安排下一次同步。"
        }
    }
    /// Small native vector icon, including a shape cue so status does not rely on color alone.
    var image: NSImage {
        let mark = self.mark, color = self.color
        return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            color.setStroke(); color.setFill()
            func line(_ points: [NSPoint]) {
                let path = NSBezierPath(); path.lineWidth = 1.6; path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }; path.stroke()
            }
            let ring = NSBezierPath(); ring.lineWidth = 1.4
            ring.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 7.5, startAngle: 40, endAngle: 195)
            ring.stroke()
            let bottom = NSBezierPath(); bottom.lineWidth = 1.4
            bottom.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 7.5, startAngle: 220, endAngle: 375)
            bottom.stroke()
            line([NSPoint(x: 2, y: 12), NSPoint(x: 2.7, y: 8), NSPoint(x: 6, y: 10)])
            line([NSPoint(x: 14, y: 10), NSPoint(x: 17.3, y: 12), NSPoint(x: 18, y: 8)])
            switch mark {
            case .complete: line([NSPoint(x: 6.5, y: 10), NSPoint(x: 9, y: 7.5), NSPoint(x: 13.5, y: 12.5)])
            case .attention:
                line([NSPoint(x: 10, y: 13), NSPoint(x: 10, y: 10)])
                NSBezierPath(ovalIn: NSRect(x: 9.1, y: 6.3, width: 1.8, height: 1.8)).fill()
            case .locked:
                let lock = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 6, width: 7, height: 6), xRadius: 1, yRadius: 1); lock.fill()
                let shackle = NSBezierPath(roundedRect: NSRect(x: 8, y: 10, width: 4, height: 5), xRadius: 2, yRadius: 2); shackle.lineWidth = 1.3; shackle.stroke()
            case .off: line([NSPoint(x: 7, y: 10), NSPoint(x: 13, y: 10)])
            case .cancelled:
                line([NSPoint(x: 8, y: 7), NSPoint(x: 8, y: 13)]); line([NSPoint(x: 12, y: 7), NSPoint(x: 12, y: 13)])
            case .waiting:
                line([NSPoint(x: 10, y: 13), NSPoint(x: 10, y: 10), NSPoint(x: 12, y: 9)])
            case .working: NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 4, height: 4)).fill()
            }
            return true
        }
    }
}


extension WorkspaceController {
    func configureSyncStatusButton() {
        syncStatusButton.title = ""; syncStatusButton.imagePosition = .imageOnly; syncStatusButton.bezelStyle = .texturedRounded
        syncStatusButton.identifier = .init("toolbar.syncStatus")
        syncStatusButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        syncStatusButton.target = self; syncStatusButton.action = #selector(showSyncStatus)
        refreshSyncStatusButton()
    }
    func refreshSyncStatusButton() {
        let sync = windowCoordinator?.webDAV, presentation = SyncStatusPresentation(sync: sync)
        syncStatusButton.presentation = presentation
        syncStatusButton.isEnabled = isSecurityUnlocked && !loadFailed
        syncStatusButton.setAccessibilityLabel("多设备同步：" + presentation.title)
        let method = presentation.directory ? "同步目录" : presentation.backendName
        let success = sync?.summary.lastSuccess.map { "\n最近成功：" + DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? ""
        syncStatusButton.toolTip = "多设备同步 · \(method)\n\(presentation.title)\(success)\n点击查看同步进度、立即同步或打开配置。"
    }
    @objc func showSyncStatus() {
        guard isSecurityUnlocked, NSApp.modalWindow == nil, window?.attachedSheet == nil else { return }
        windowCoordinator?.showSyncStatus()
    }
    @objc func showSyncPreferences() {
        guard isSecurityUnlocked, NSApp.modalWindow == nil, window?.attachedSheet == nil else { return }
        editPreferences(appearanceSelected: false, storageSelected: true)
    }
}
