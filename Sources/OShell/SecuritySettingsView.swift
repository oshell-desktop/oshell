// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import LocalAuthentication
import OShellCore

final class SecuritySettingsView: NSView {
    let touchID = NSButton(checkboxWithTitle: "在此 Mac 使用 Touch ID 快捷解锁", target: nil, action: nil)
    private weak var workspace: WorkspaceController?
    private let originallyEnabled: Bool
    init(workspace: WorkspaceController) {
        self.workspace = workspace; originallyEnabled = BiometricUnlock.shared.enabled
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        let title = NSTextField(labelWithString: "主密码与 Touch ID")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        touchID.identifier = .init("settings.security.touchID"); touchID.state = originallyEnabled ? .on : .off
        let available = workspace.configuration.masterPasswordVerifier != nil && BiometricUnlock.shared.unavailableReason == nil
        touchID.isEnabled = available || originallyEnabled
        let status = NSTextField(wrappingLabelWithString: workspace.configuration.hasMasterPassword
            ? (BiometricUnlock.shared.unavailableReason ?? (originallyEnabled ? "已在此 Mac 启用。打开解锁窗口会自动验证指纹，也可手动输入主密码。" : "此 Mac 支持 Touch ID。勾选后点击“应用”，输入当前主密码完成启用。"))
            : "请先通过顶部“工具 → 设置主密码”启用主密码保护，再设置 Touch ID。")
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let help = NSTextField(wrappingLabelWithString: "主密码经 Secure Enclave 保护后，以加密记录保存在本机私有目录；解密必须验证当前指纹。不保存明文，不写入会话文件，也不随 iCloud / WebDAV 同步。\n\n更换 Mac、变更指纹或主密码后需要重新启用。从旧钥匙串记录迁移失败时，请先手动解锁，再关闭并重新开启本选项；新记录无需在每次升级后授权钥匙串。请继续妥善保管主密码，指纹解锁不能用于恢复遗忘的主密码。")
        help.font = .systemFont(ofSize: 12); help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, touchID, status, help]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), status.widthAnchor.constraint(equalTo: stack.widthAnchor), help.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applySelection() throws {
        let enabled = touchID.state == .on
        guard enabled != originallyEnabled, let workspace else { return }
        if !enabled { try BiometricUnlock.shared.disable(); return }
        if let reason = BiometricUnlock.shared.unavailableReason { throw ModelError.invalid(reason) }
        guard let binding = BiometricUnlock.binding(workspace.configuration), let scope = BiometricUnlock.shared.scope else { throw ModelError.invalid("请先设置主密码。") }
        guard let password = PasswordVault.promptMaster(title: "输入当前主密码以启用 Touch ID", creating: false) else { return }
        let snapshot = workspace.configuration, revision = workspace.configurationRevision
        let context = LAContext(); defer { context.invalidate() }
        guard let result = CredentialTask.run(title: "正在启用 Touch ID…", message: "验证主密码并准备仅限此 Mac 的指纹解锁记录。", work: { token in
            try MasterPasswordProtection.verifyStartup(snapshot, password: password)
            try token.check()
            let data = try BiometricCipher.seal(password, scope: scope, context: context)
            try token.check(); return data
        }) else { return }
        let data = try result.get()
        guard revision == workspace.configurationRevision else { throw ModelError.invalid("配置已变化，Touch ID 未启用，请重试。") }
        try BiometricUnlock.shared.savePrepared(data, binding: binding, expectedScope: scope)
    }
}
