// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class UpdateSettingsView: NSView {
    let repository = NSTextField(), automatic = NSButton(checkboxWithTitle: "每天自动检查更新（安装前仍需确认）", target: nil, action: nil)
    let installTerminal = NSButton(checkboxWithTitle: "更新 OShell 时同时安装或更新 oTerm", target: nil, action: nil)
    init(preferences: Preferences) {
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        repository.identifier = .init("updates.repository"); automatic.identifier = .init("updates.automatic")
        repository.stringValue = preferences.updateRepository.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "OShellUpdateRepository") as? String ?? "") : preferences.updateRepository
        repository.placeholderString = "owner/repo 或 https://github.com/owner/repo"
        automatic.state = preferences.automaticUpdateChecks ? .on : .off
        installTerminal.identifier = .init("updates.installLocalTerminal")
        installTerminal.state = LocalTerminalUpdate.enabled ? .on : .off
        let terminalHelp = NSTextField(wrappingLabelWithString: "从下次版本升级开始生效。oTerm 正在使用时，等它退出后再更新。取消勾选会保留已安装的 oTerm。")
        terminalHelp.textColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "GitHub Pages 更新")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let current = NSTextField(labelWithString: "当前版本：\(version) · 安装包类型：\(UpdateFlavor.current.rawValue)")
        current.textColor = .secondaryLabelColor
        let help = NSTextField(wrappingLabelWithString: "从对应仓库的 GitHub Pages 获取签名更新信息，不调用 GitHub API，无需登录或 Token；留空则不检查更新。\n\n维护者需启用 Pages 更新站点。安装包仍从 Releases 下载，下载后会验证签名。安装前确认关闭活动会话，完成后自动重启。会话配置与已保存的密码会保留。")
        let stack = NSStackView(views: [title, current, NSTextField(labelWithString: "更新仓库"), repository, automatic, installTerminal, terminalHelp, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), repository.widthAnchor.constraint(equalTo: stack.widthAnchor), terminalHelp.widthAnchor.constraint(equalTo: stack.widthAnchor), help.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func values(updating original: Preferences) throws -> Preferences {
        var value = original
        let text = repository.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && automatic.state == .on { throw ModelError.invalid("请先填写更新仓库，或关闭自动检查。") }
        value.updateRepository = text.isEmpty ? "" : try UpdateSource(text).repository
        value.automaticUpdateChecks = automatic.state == .on
        return value
    }
}
