// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum SessionTitleDisplayMode: String, Codable, CaseIterable {
    case sessionName, activeProbe, passive, shellIntegration
    init(_ mode: HostTitleMode) { self = Self(rawValue: mode.rawValue)! }
    var hostMode: HostTitleMode { HostTitleMode(rawValue: rawValue) ?? .shellIntegration }
    var title: String { self == .sessionName ? "仅显示会话名称" : hostMode.title }
    var explanation: String {
        self == .sessionName ? "使用保存的会话名称，不随远端提示符变化，不主动探测；已识别的主机信息仍可在悬停详情中查看。此标题选择仅保存在本机。" : hostMode.explanation
    }
}

struct SessionTitleSettings: Codable, Equatable {
    var version = 1
    var defaultMode: SessionTitleDisplayMode = .sessionName
    var overrides = [String: SessionTitleDisplayMode]()
    var confirmTabClose = true
    private enum CodingKeys: String, CodingKey { case version, defaultMode, overrides, confirmTabClose }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        defaultMode = try values.decode(SessionTitleDisplayMode.self, forKey: .defaultMode)
        overrides = try values.decode([String: SessionTitleDisplayMode].self, forKey: .overrides)
        // Existing local files predate this option; retain the previous confirmation behavior.
        confirmTabClose = try values.decodeIfPresent(Bool.self, forKey: .confirmTabClose) ?? true
    }
    static var shouldConfirmTabClose: Bool { (try? load().confirmTabClose) ?? true }
    static var url: URL { StorageLocation.localStateDirectory.appendingPathComponent("tab-title-settings.json") }
    static let didChange = Notification.Name("OShellTabTitleSettingsChanged")
    static func load() throws -> Self {
        guard let data = try SharedDataFile.readIfPresent(url) else { return .init() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw ModelError.invalid("标签标题设置版本不受支持，请升级客户端。") }
        return value
    }
    func mode(for profile: SessionProfile) -> SessionTitleDisplayMode {
        overrides[profile.id.uuidString.lowercased()] ?? SessionTitleDisplayMode(profile.titleMode)
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(self), to: Self.url)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    static func set(_ mode: SessionTitleDisplayMode, for id: UUID) throws {
        var value = try load(); value.overrides[id.uuidString.lowercased()] = mode; try value.save()
    }

}

final class SessionTitleSettingsView: NSView {
    private let mode = NSPopUpButton(), explanation = NSTextField(wrappingLabelWithString: "")
    private let confirmClose = NSButton(checkboxWithTitle: "关闭标签前确认", target: nil, action: nil)
    private let overwrite = NSButton(checkboxWithTitle: "同时覆盖所有已有会话和已打开终端的标题方式", target: nil, action: nil)
    private let original: SessionTitleSettings
    private let loadError: Error?
    init() {
        let loaded = Result { try SessionTitleSettings.load() }
        original = (try? loaded.get()) ?? .init()
        if case .failure(let error) = loaded { loadError = error } else { loadError = nil }
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 440))
        let heading = NSTextField(labelWithString: "标签"); heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let label = NSTextField(labelWithString: "新建会话默认标题方式")
        mode.identifier = .init("titles.defaultMode"); overwrite.identifier = .init("titles.overwriteExisting")
        mode.addItems(withTitles: SessionTitleDisplayMode.allCases.map(\.title))
        mode.selectItem(at: SessionTitleDisplayMode.allCases.firstIndex(of: original.defaultMode)!)
        mode.target = self; mode.action = #selector(updateDescription)
        overwrite.state = .off
        confirmClose.identifier = .init("tabs.confirmClose")
        confirmClose.state = original.confirmTabClose ? .on : .off
        let closeHelp = NSTextField(wrappingLabelWithString: "标签或分屏中仍有连接、进程运行时，关闭前弹出确认。关闭此选项后立即结束对应会话；空白或已结束的标签直接关闭。仅本机生效，所有窗口通用；不影响关闭整个窗口或退出程序的确认。")
        closeHelp.font = .systemFont(ofSize: 12); closeHelp.textColor = .secondaryLabelColor
        let help = NSTextField(wrappingLabelWithString: "不勾选覆盖时，已有会话保持自己的标题方式；勾选并点击“应用”后统一更新，已打开的标签立即生效，无需重连。会话属性中仍可单独选择。全局默认和本机标题选择不参与同步或导出，不修改原有共享协议字段。空白标签和命令行临时连接继续显示当前状态。")
        for text in [explanation, help] { text.font = .systemFont(ofSize: 12); text.textColor = .secondaryLabelColor }
        let row = NSStackView(views: [label, mode]); row.spacing = 16
        let stack = NSStackView(views: [heading, row, explanation, overwrite, help, confirmClose, closeHelp])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), explanation.widthAnchor.constraint(equalTo: stack.widthAnchor), help.widthAnchor.constraint(equalTo: stack.widthAnchor), closeHelp.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        updateDescription()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func updateDescription() { explanation.stringValue = SessionTitleDisplayMode.allCases[mode.indexOfSelectedItem].explanation }
    func apply(profiles: [SessionProfile]) throws {
        if let loadError { throw loadError }
        let selected = SessionTitleDisplayMode.allCases[mode.indexOfSelectedItem]
        guard selected != original.defaultMode || overwrite.state == .on || (confirmClose.state == .on) != original.confirmTabClose else { return }
        var current = try SessionTitleSettings.load()
        guard current == original else { throw ModelError.invalid("其他窗口已修改标题设置，请重新打开设置后应用。") }
        current.defaultMode = selected
        current.confirmTabClose = confirmClose.state == .on
        if overwrite.state == .on { for profile in profiles { current.overrides[profile.id.uuidString.lowercased()] = selected } }
        try current.save()
    }
}

extension WorkspaceController {
    func saveSessionTitleChoice(_ choice: (UUID, SessionTitleDisplayMode)?) {
        guard let choice else { return }
        do { try SessionTitleSettings.set(choice.1, for: choice.0) }
        catch { Dialogs.message("会话已保存，但本机标题设置未保存：" + error.localizedDescription) }
    }
    func copySessionTitleChoices(from sources: [SessionProfile], to copies: [SessionProfile]) {
        do {
            var settings = try SessionTitleSettings.load()
            for (source, copy) in zip(sources, copies) { settings.overrides[copy.id.uuidString.lowercased()] = settings.mode(for: source) }
            try settings.save()
        } catch { Dialogs.message("会话已复制，但本机标题设置未保存：" + error.localizedDescription) }
    }
    func refreshSessionTitleDisplays() {
        guard let settings = try? SessionTitleSettings.load() else { return }
        let names = Dictionary(configuration.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for pane in inputPanes {
            if let name = names[pane.profile.id] { pane.updateSessionTitleName(name) }
            if let mode = settings.overrides[pane.profile.id.uuidString.lowercased()] { pane.applyTitleDisplayMode(mode) }
        }
    }
}
