// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Each tab owns its backend, worker queue and complete browsing/transfer UI.
final class RemoteFileWindow: NSWindowController, NSWindowDelegate {
    override func showWindow(_ sender: Any?) {
        if let popup = window as? PopupWindow, let owner = workspace?.window { popup.present(over: owner) }
        else { super.showWindow(sender) }
    }
    private weak var workspace: WorkspaceController?
    private let strip = TabStripView(), host = NSView()
    private(set) var sessions = [RemoteFileSession]()
    private(set) var selectedSession: RemoteFileSession?
    private var closed = false
    private let backendFactory: ((SessionProfile) throws -> RemoteFileBackend)?
    var onClosed: (() -> Void)?
    var hasActiveOperation: Bool { sessions.contains(where: \.hasActiveOperation) }
    init(workspace: WorkspaceController, backendFactory: ((SessionProfile) throws -> RemoteFileBackend)? = nil) {
        self.workspace = workspace; self.backendFactory = backendFactory
        let window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.attachesToOwner = false
        window.title = "文件管理 · SFTP / FTP"; window.minSize = NSSize(width: 800, height: 490); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center()
        let root = window.contentView!
        [strip, host].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.topAnchor), strip.leadingAnchor.constraint(equalTo: root.leadingAnchor), strip.trailingAnchor.constraint(equalTo: root.trailingAnchor), strip.heightAnchor.constraint(equalToConstant: TabStripView.barHeight),
            host.topAnchor.constraint(equalTo: strip.bottomAnchor), host.leadingAnchor.constraint(equalTo: root.leadingAnchor), host.trailingAnchor.constraint(equalTo: root.trailingAnchor), host.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        strip.setAddDescription("从会话管理新建文件标签")
        strip.allowsTabDragging = true
        strip.canAcceptTab = { [weak self] id in self?.sessions.contains(where: { $0.id == id }) == true }
        strip.onReorderTab = { [weak self] id, before in self?.reorderSession(id, before: before) ?? false }
        strip.onDragEnd = { [weak self] in self?.strip.clearDragPreview() }
        strip.onAdd = { [weak self] in self?.chooseSession() }
        strip.onSelect = { [weak self] id in if let session = self?.sessions.first(where: { $0.id == id }) { self?.select(session) } }
        strip.onClose = { [weak self] id in self?.closeTab(id) }
        strip.onDuplicate = { [weak self] id in
            guard let self, let session = self.sessions.first(where: { $0.id == id }), let profile = session.profile else { return }
            self.open(profile, directory: session.directory, password: session.transientPassword, connectionGroup: session.connectionGroup)
        }
        _ = addBlank()
    }
    /// Transfer ownership without closing any backend or interrupting transfers.
    func reassignWorkspace(_ workspace: WorkspaceController) {
        guard !closed else { return }
        self.workspace = workspace
        sessions.forEach { $0.reassignWorkspace(workspace) }
        onClosed = { [weak workspace, weak self] in
            guard let self else { return }; workspace?.fileWindows.removeAll { $0 === self }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @discardableResult private func addBlank() -> RemoteFileSession? {
        guard let workspace, !closed else { return nil }
        let session = RemoteFileSession(workspace: workspace, backendFactory: backendFactory)
        session.onStateChanged = { [weak self] in self?.updateTabs() }
        session.onChooseConnection = { [weak self] in self?.chooseSession() }
        sessions.append(session); select(session); return session
    }
    func show(profile: SessionProfile? = nil, directory: String = ".", uploading: [URL] = [], password: String? = nil, connectionGroup: SSHConnectionGroup? = nil) {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        if let profile { open(profile, directory: directory, uploading: uploading, password: password, connectionGroup: connectionGroup) } else { chooseSession() }
    }
    func open(_ profile: SessionProfile, directory: String? = nil, uploading: [URL] = [], password: String? = nil, connectionGroup: SSHConnectionGroup? = nil) {
        guard !closed, profile.kind != .local else { return }
        let session = selectedSession?.profile == nil ? selectedSession : addBlank()
        guard let session else { return }
        select(session); session.connect(profile, directory: directory, uploading: uploading, password: password, connectionGroup: connectionGroup); updateTabs()
    }
    @discardableResult func reorderSession(_ id: UUID, before: UUID?) -> Bool {
        guard !closed, let session = sessions.first(where: { $0.id == id }),
              before == nil || sessions.contains(where: { $0.id == before }) else { return false }
        if before == id { return true }
        sessions.removeAll { $0.id == id }
        sessions.insert(session, at: before.flatMap { target in sessions.firstIndex { $0.id == target } } ?? sessions.count)
        select(session); return true
    }
    func select(_ session: RemoteFileSession) {
        guard !closed, sessions.contains(where: { $0 === session }) else { return }
        selectedSession = session; host.subviews.forEach { $0.removeFromSuperview() }
        session.view.frame = host.bounds; session.view.autoresizingMask = [.width, .height]; host.addSubview(session.view)
        updateTabs(); strip.revealSelection()
    }
    private func updateTabs() {
        strip.update(entries: sessions.map { .init(id: $0.id, title: $0.tabTitle, detail: ($0.profile?.kind == .ftp ? "FTP" : "SFTP") + " · " + ($0.profile?.host ?? "") + "\n" + $0.directory + "\n双击新建相同文件会话") }, selectedID: selectedSession?.id)
        window?.title = "文件管理 · " + (selectedSession?.tabTitle ?? "SFTP / FTP")
    }
    func closeTab(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        if session.hasActiveOperation && !Dialogs.confirm("关闭正在处理的文件标签？", text: "只取消此标签的连接或传输；其他标签继续运行。", action: "关闭标签") { return }
        let wasSelected = selectedSession === session
        session.shutdown(); session.view.removeFromSuperview(); sessions.remove(at: index)
        if sessions.isEmpty { selectedSession = nil; _ = addBlank() }
        else if wasSelected { select(sessions[min(index, sessions.count - 1)]) }
        updateTabs()
    }
    private func chooseSession() {
        guard !closed else { return }
        workspace?.showFileSessions { [weak self] profile in
            guard let self, !self.closed else { return }
            self.showWindow(nil); self.window?.makeKeyAndOrderFront(nil); self.open(profile)
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if let workspace { workspace.windowCoordinator?.activate(workspace) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !hasActiveOperation || Dialogs.confirm("关闭文件管理？", text: "将取消所有文件标签中的连接和传输。", action: "关闭")
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true
        sessions.forEach { $0.shutdown() }; sessions = []; selectedSession = nil; host.subviews.forEach { $0.removeFromSuperview() }
        onClosed?(); onClosed = nil
    }
}

extension WorkspaceController {
    var credentialProfiles: [SessionProfile] { ConfigurationCredentials.profiles(in: configuration) }
    @objc func showFiles() {
        if let pane = selectedTab?.activePane, !pane.ended, pane.profile.kind.usesSSH { openFiles(from: pane) }
        else { openFiles(for: nil) }
    }
    func openFiles(from pane: TerminalPane, uploading: [URL] = []) {
        guard isSecurityUnlocked, !pane.isShutdown, !pane.ended, pane.profile.kind.usesSSH else { return }
        guard let group = pane.sshConnectionGroup, group.isAvailable else {
            Dialogs.message("当前 SSH 连接尚未完成认证或已失效。请先重新连接 SSH 会话，再打开 SFTP 文件管理。"); return
        }
        openFiles(for: pane.profile, directory: pane.remoteDirectory, uploading: uploading, connectionGroup: group)
    }
    func openFiles(for profile: SessionProfile?, directory: String = ".", uploading: [URL] = [], password: String? = nil, connectionGroup: SSHConnectionGroup? = nil) {
        guard isSecurityUnlocked else { return }
        let manager: RemoteFileWindow
        if let existing = fileWindows.first { manager = existing }
        else {
            manager = RemoteFileWindow(workspace: self); fileWindows.append(manager)
            manager.onClosed = { [weak self, weak manager] in guard let manager else { return }; self?.fileWindows.removeAll { $0 === manager } }
        }
        manager.show(profile: profile, directory: directory, uploading: uploading, password: password, connectionGroup: connectionGroup)
    }
}

extension WorkspaceController {
    func openExternalFile(_ request: FileLaunchRequest) {
        guard isSecurityUnlocked else { return }
        NSApp.activate(ignoringOtherApps: true)
        openFiles(for: request.profile, directory: request.profile.initialDirectory, password: request.password)
    }
}
