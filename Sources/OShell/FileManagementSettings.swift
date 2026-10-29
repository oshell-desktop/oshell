// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// Native presentation and a user-authored local command. Never part of the
/// shared Swift/Go vault or WebDAV configuration.
struct FileManagementSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case builtIn, terminal
        var title: String { self == .builtIn ? "OShell 内置文件管理" : "当前终端运行命令" }
    }
    enum Placement: String, Codable, CaseIterable {
        case window, left, right, bottom
        var title: String { switch self { case .window: return "独立窗口"; case .left: return "窗口左侧"; case .right: return "窗口右侧"; case .bottom: return "窗口底部" } }
    }
    var version = 1
    var mode: Mode = .builtIn
    var placement: Placement = .window
    var command = "yazi"
    static let changed = Notification.Name("OShellFileManagementSettingsChanged")
    static var url: URL { StorageLocation.localStateDirectory.appendingPathComponent("file-management.json") }
    func validate() throws {
        guard version == 1 else { throw ModelError.invalid("文件管理设置版本不受支持，请升级客户端。") }
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty, command.utf8.count <= 4096,
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ModelError.invalid("文件管理命令须为非空的单行文本，最多 4096 字节，不能包含控制字符。")
        }
    }
    static func load() throws -> Self {
        guard let data = try SharedDataFile.readIfPresent(url) else { return .init() }
        let result = try JSONDecoder().decode(Self.self, from: data); try result.validate(); return result
    }
    func save() throws {
        try validate()
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(self), to: Self.url)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

final class FileManagementSettingsView: NSView {
    private let mode = NSPopUpButton(), placement = NSPopUpButton(), command = NSComboBox()
    private let commandHint = NSTextField(wrappingLabelWithString: "命令在当前终端、当前目录执行。SSH 会话需要在远端安装对应工具，本地会话需要在本机安装。不会自动安装软件或另开隐藏连接。")
    private var initial = FileManagementSettings(), loadError: Error?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        do { initial = try FileManagementSettings.load() } catch { loadError = error }
        mode.addItems(withTitles: FileManagementSettings.Mode.allCases.map(\.title)); mode.selectItem(withTitle: initial.mode.title)
        placement.addItems(withTitles: FileManagementSettings.Placement.allCases.map(\.title)); placement.selectItem(withTitle: initial.placement.title)
        command.addItems(withObjectValues: ["yazi", "ranger", "lf", "nnn", "mc"]); command.stringValue = initial.command
        mode.identifier = .init("settings.files.mode"); placement.identifier = .init("settings.files.placement"); command.identifier = .init("settings.files.command")
        mode.target = self; mode.action = #selector(updateMode)
        let title = AppUI.label("打开方式与位置", size: 13, weight: .semibold)
        let intro = AppUI.label("切换内置面板位置时，文件标签、连接与传输会保留。", secondary: true)
        func row(_ title: String, _ control: NSView) -> NSView {
            let label = AppUI.label(title); label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            control.widthAnchor.constraint(equalToConstant: 360).isActive = true
            return AppUI.row([label, control, NSView()])
        }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        for view in [title, intro, row("打开方式", mode), row("内置面板位置", placement), row("文件管理命令", command), commandHint,
                     AppUI.label("内置模式可拖动分隔线调整面板大小，切换位置保留文件标签和传输。终端模式只向当前会话发送命令，启动前需确认 Shell 空闲。", secondary: true),
                     AppUI.label("SFTP / FTP 会话、外部文件链接和上传仍使用内置管理器。这些设置仅保存在本机，不参与共享配置同步。", secondary: true)] {
            AppUI.add(view, to: stack)
        }
        commandHint.font = .systemFont(ofSize: 12); commandHint.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)])
        updateMode()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func updateMode() {
        let native = mode.indexOfSelectedItem == 0
        placement.isEnabled = native; command.isEnabled = !native
    }
    func values() throws -> FileManagementSettings {
        if let loadError { throw loadError }
        var result = initial; result.mode = FileManagementSettings.Mode.allCases[mode.indexOfSelectedItem]
        result.placement = FileManagementSettings.Placement.allCases[placement.indexOfSelectedItem]
        result.command = command.stringValue.trimmingCharacters(in: .whitespaces)
        try result.validate(); return result
    }
    func apply() throws { let result = try values(); if result != initial { try result.save() } }
}

extension WorkspaceController {
    func terminalFileCommandBlockReason(_ pane: TerminalPane?) -> String? {
        guard isSecurityUnlocked, let pane, pane.agentEligible, pane.acceptsManagedInput else { return "请先选择已连接的 SSH 终端或运行中的本地 Shell。" }
        if let grant = AgentCoordinator.shared.grants[pane.id], grant.task != nil || grant.integrationPending { return "当前终端由 MCP 任务占用，请先在 MCP 控制中心接管。" }
        guard pane.agentCanInitialize else { return "当前终端正在输入、传输、认证或运行交互程序。请先回到空闲 Shell，避免将文件管理命令输入到其他程序。" }
        return nil
    }
    @discardableResult func launchTerminalFileManager(in target: TerminalPane? = nil) -> Bool {
        let pane = target ?? selectedTab?.activePane
        if let reason = terminalFileCommandBlockReason(pane) { Dialogs.message(reason); return false }
        guard let pane else { return false }
        do {
            let command = try FileManagementSettings.load().command
            let generation = pane.agentGeneration
            guard Dialogs.confirm("在当前终端启动文件管理？", text: "目标：\(pane.title)\n命令：\(command)\n\n请确认当前 Shell 空闲，没有正在运行的命令或密码提示。命令仅发送到此会话，不会同步输入到其他终端。", action: "确认空闲并运行") else { return false }
            guard generation == pane.agentGeneration, inputPanes.contains(where: { $0 === pane }), terminalFileCommandBlockReason(pane) == nil else {
                Dialogs.message("目标连接或输入状态已变化，未发送命令。"); return false
            }
            AgentCoordinator.shared.takeover(pane.id, reason: "用户启动终端文件管理", interrupt: false)
            pane.activate(); pane.sendManaged(Array((command + "\r").utf8)); return true
        } catch { Dialogs.message(error.localizedDescription); return false }
    }
}
