// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class AboutSettingsView: NSView {
    private let projectURL: URL?
    init(preferences: Preferences) {
        let repository = preferences.updateRepository.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "OShellUpdateRepository") as? String ?? "") : preferences.updateRepository
        projectURL = (try? UpdateSource(repository)).flatMap { URL(string: "https://github.com/" + $0.repository) }
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage; icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("OShell 应用图标")
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let title = NSTextField(labelWithString: "OShell")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "macOS SSH 与文件传输客户端")
        subtitle.textColor = .secondaryLabelColor
        let identity = NSStackView(views: [title, subtitle])
        identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 8
        let header = NSStackView(views: [icon, identity]); header.spacing = 20; header.alignment = .centerY

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        let buildLabel = (info["OShellBuildLabel"] as? String).map { " · " + $0 } ?? ""
        let minimum = info["LSMinimumSystemVersion"] as? String ?? "—"
        #if arch(arm64)
        let architecture = "Apple Silicon（arm64）"
        #elseif arch(x86_64)
        let architecture = "Intel（x86_64）"
        #else
        let architecture = "—"
        #endif
        func row(_ name: String, _ text: String, id: String) -> NSView {
            let label = NSTextField(labelWithString: name); label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let value = NSTextField(labelWithString: text); value.isSelectable = true
            value.identifier = .init("about." + id)
            let row = NSStackView(views: [label, value]); row.spacing = 20; row.alignment = .centerY
            return row
        }
        let details = NSStackView(views: [
            row("版本", "\(version)（构建 \(build)）\(buildLabel)", id: "version"),
            row("当前架构", architecture, id: "architecture"),
            row("系统要求", "macOS \(minimum) 或更新版本", id: "minimumOS"),
            row("开源许可证", "GNU GPL v3（GPL-3.0-only）", id: "license")
        ])
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 16
        let card = NSBox(); card.titlePosition = .noTitle; card.boxType = .primary
        card.contentViewMargins = NSSize(width: 20, height: 20)
        let content = card.contentView!
        details.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(details)
        NSLayoutConstraint.activate([
            details.leadingAnchor.constraint(equalTo: content.leadingAnchor), details.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            details.topAnchor.constraint(equalTo: content.topAnchor), details.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])
        let buttons = NSStackView(); buttons.spacing = 12
        for (label, id) in [("项目主页", "project"), ("开源许可证", "license"), ("第三方声明", "notices")] {
            let button = NSButton(title: label, target: self, action: #selector(openResource(_:)))
            button.bezelStyle = .rounded; button.identifier = .init("about.open." + id)
            if id == "project" {
                button.isEnabled = projectURL != nil
                button.toolTip = projectURL?.absoluteString ?? "请先在更新页配置项目的 GitHub 仓库。"
            }
            buttons.addArrangedSubview(button)
        }
        let copyright = NSTextField(labelWithString: "© 2026 OShell contributors · 本软件不提供任何担保。")
        copyright.font = .systemFont(ofSize: 11); copyright.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, card, buttons, copyright])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -44),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor), card.heightAnchor.constraint(equalToConstant: 180)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openResource(_ sender: NSButton) {
        let url: URL?
        switch sender.identifier?.rawValue {
        case "about.open.project": url = projectURL
        case "about.open.license": url = Bundle.main.url(forResource: "OShell-LICENSE", withExtension: "txt")
        case "about.open.notices": url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt")
        default: return
        }
        guard let url, NSWorkspace.shared.open(url) else { Dialogs.message("无法打开所选页面或文件。"); return }
    }
}
