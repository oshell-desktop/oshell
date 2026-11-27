// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

extension WorkspaceController {
    private func savedBastion(_ pane: TerminalPane) -> SessionProfile? {
        let opening = pane.profile
        guard isSecurityUnlocked, opening.kind == .ssh, !pane.isBlank,
              !pane.reusesSSHConnection, pane.sshConnectionGroup?.isExternal != true,
              BastionAccount(opening.username) != nil,
              let saved = configuration.profiles.first(where: { $0.id == opening.id }),
              opening.runtimeSSHMode != .terminal, store.sshMode(for: saved) == .bastion,
              saved.kind == opening.kind, saved.host == opening.host, saved.port == opening.port,
              saved.username == opening.username else { return nil }
        return saved
    }

    func bindBastion(_ pane: TerminalPane) {
        guard savedBastion(pane) != nil else { return }
        pane.savedBastionProfile = { [weak self, weak pane] in
            guard let pane else { return nil }
            return self?.savedBastion(pane)
        }
        pane.targetPromptHandler = { [weak self, weak pane] event in
            guard let self, let pane, pane.targetPrompt?.awaitingAnswer == true,
                  let (profile, identity) = currentTarget(pane) else { return }
            do {
                if case .password = event, let secret = try store.targetPassword(profile, identity: identity) {
                    try sendTarget(secret, pane: pane, submit: true)
                } else {
                    try askForTarget(pane, retry: event == .retry, login: true)
                }
            } catch { pane.targetPrompt?.cancel(); Dialogs.message("目标密码无法使用：" + error.localizedDescription) }
        }
    }

    private func currentTarget(_ pane: TerminalPane) -> (SessionProfile, SSHIdentity)? {
        guard let profile = savedBastion(pane), pane.connectionIsActive, pane.sessionReady,
              !pane.isTransferring, AgentCoordinator.shared.grants[pane.id]?.controlActive != true,
              let actual = pane.targetIdentity, (try? SSHIdentity.resolve(profile)) == actual else { return nil }
        return (profile, actual)
    }

    private func sendTarget(_ secret: String, pane: TerminalPane, submit: Bool) throws {
        guard currentTarget(pane) != nil, !submit || pane.targetPrompt?.awaitingAnswer == true else { return }
        try ConfigurationStore.validateTargetSecret(secret)
        try pane.agentOutputRedactor.add(secret)
        try pane.agentDisplayRedactor.add(secret)
        pane.agentSensitiveObservationBlocked = true
        if submit { pane.targetPrompt?.submitted() } else { pane.targetPrompt?.cancel() }
        pane.sendingTargetPassword = true
        pane.agentInputKind = "sensitive"
        defer { pane.agentInputKind = nil; pane.sendingTargetPassword = false }
        pane.terminal.process.send(data: Array((secret + (submit ? "\r" : "")).utf8)[...])
    }

    private func askForTarget(_ pane: TerminalPane, retry: Bool, login: Bool) throws {
        guard let (profile, identity) = currentTarget(pane), let account = BastionAccount(profile.username) else { return }
        let revision = try store.targetRevision(profile.id)
        let alert = PopupAlert.terminalOperation()
        alert.messageText = retry ? "目标服务器再次要求密码，请核对后重试" : "目标服务器密码"
        alert.informativeText = "堡垒机：" + identity.host + "    资产：" + account.asset + "    目标账号：" + account.user
        let field = PasswordEntryView(identifier: "bastion.target.password")
        let remember = NSButton(checkboxWithTitle: "在本机保存目标服务器密码", target: nil, action: nil)
        let content = NSStackView(views: login ? [field, remember] : [field])
        content.orientation = .vertical; content.alignment = .leading
        content.frame = NSRect(x: 0, y: 0, width: 420, height: login ? 60 : 30)
        field.widthAnchor.constraint(equalToConstant: 420).isActive = true
        alert.accessoryView = content; alert.window.initialFirstResponder = field.secureField
        alert.addButton(withTitle: login ? "登录" : "保存"); alert.addButton(withTitle: "取消")
        defer { field.clear() }
        guard alert.runModal() == .alertFirstButtonReturn else { if login { pane.targetPrompt?.cancel() }; return }
        guard let (latest, actual) = currentTarget(pane), latest == profile, actual == identity,
              !login || pane.targetPrompt?.awaitingAnswer == true else { return }
        let secret = field.stringValue
        try ConfigurationStore.validateTargetSecret(secret)
        if !login || remember.state == .on {
            guard saveConfiguration(configuration, targetEdit: .init(id: profile.id, expectedRevision: revision, change: .replace(secret))) else { return }
        }
        if login { try sendTarget(secret, pane: pane, submit: true) }
    }

    func appendTargetPasswordItems(to menu: NSMenu, pane: TerminalPane) {
        guard currentTarget(pane) != nil else { return }
        for (title, action) in [("保存或更新目标密码…", #selector(updateTargetPassword(_:))), ("忘记目标密码…", #selector(forgetTargetPassword(_:))), ("填入目标密码（手动回车）", #selector(fillTargetPassword(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = pane
        }
        menu.addItem(.separator())
    }

    @objc private func updateTargetPassword(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? TerminalPane else { return }
        do { try askForTarget(pane, retry: false, login: false) } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func forgetTargetPassword(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? TerminalPane, let (profile, _) = currentTarget(pane) else { return }
        do {
            let revision = try store.targetRevision(profile.id)
            let alert = PopupAlert.terminalOperation()
            alert.messageText = "忘记此会话的目标服务器密码？"
            alert.addButton(withTitle: "忘记"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn, currentTarget(pane)?.0 == profile else { return }
            _ = saveConfiguration(configuration, targetEdit: .init(id: profile.id, expectedRevision: revision, change: .clear))
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func fillTargetPassword(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? TerminalPane, let (profile, identity) = currentTarget(pane) else { return }
        do {
            guard let secret = try store.targetPassword(profile, identity: identity) else { Dialogs.message("本机尚未保存此目标服务器密码。"); return }
            try sendTarget(secret, pane: pane, submit: false)
        } catch { Dialogs.message(error.localizedDescription) }
    }
}
