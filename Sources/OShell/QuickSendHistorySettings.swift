// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum QuickSendHistoryPreferences {
    static let key = "OShell.quickSend.historyLimit"
    static let range = 1...100000
    static var limit: Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return range.contains(value) ? value : 500
    }
}

final class QuickSendHistorySettingsControl: NSStackView {
    let count = NSTextField(string: String(QuickSendHistoryPreferences.limit))
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 110))
        orientation = .vertical; alignment = .leading; spacing = 12
        count.identifier = .init("settings.quickSend.historyLimit")
        count.setAccessibilityLabel("快速发送历史保留条数")
        count.widthAnchor.constraint(equalToConstant: 120).isActive = true
        addArrangedSubview(AppUI.row([NSTextField(labelWithString: "历史保留条数"), count, NSTextField(labelWithString: "条")]))
        let help = NSTextField(wrappingLabelWithString: "默认保留最近 500 条，可设置 1–100000 条。超过上限自动淘汰最早记录；降低上限并应用后立即清理。历史重启保留，仅保存在本机，所有窗口共用。")
        help.textColor = .secondaryLabelColor; help.font = .systemFont(ofSize: 12)
        addArrangedSubview(help); help.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func value() throws -> Int {
        guard let value = Int(count.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), QuickSendHistoryPreferences.range.contains(value) else {
            throw ModelError.invalid("快速发送历史保留条数须为 1–100000 的整数。")
        }
        return value
    }
    func apply() throws {
        let limit = try value()
        try QuickSendHistoryStore.shared.trim(to: limit)
        UserDefaults.standard.set(limit, forKey: QuickSendHistoryPreferences.key)
    }
}
