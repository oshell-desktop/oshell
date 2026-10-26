// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import UniformTypeIdentifiers
import OShellCore

enum SessionTransfer {
    static func export(profiles: [SessionProfile], directories: [String], links: [SessionLink] = [], proxies: [ProxyProfile] = []) {
        var source = Configuration(profiles: profiles)
        do { source.proxies = try ProxyCatalog.required(for: profiles, in: proxies) }
        catch { Dialogs.message(error.localizedDescription); return }
        let current = PasswordVault.shared.currentCredentials(in: source), currentProfiles = current.profiles
        let credentials = ConfigurationCredentials.profiles(in: current)
        let hasLocal = credentials.contains { $0.encryptedPassword?.localKeyID != nil }
        let options = PopupAlert(); options.messageText = "导出会话"
        options.informativeText = "导出 \(profiles.count) 个会话、\(links.count) 个快捷引用及目录结构。包含代理、隧道、保活等连接设置；不包含私钥文件、主机指纹或终端历史。"
        options.addButton(withTitle: "选择保存位置…"); options.addButton(withTitle: "取消")
        let passwords = NSButton(checkboxWithTitle: hasLocal ? "包含已保存密码（单独设置导出文件密码）" : "包含已保存的加密密码（导入时需要原主密码）", target: nil, action: nil)
        passwords.frame = NSRect(x: 0, y: 0, width: 420, height: 26); passwords.state = .off; options.accessoryView = passwords
        guard options.runModal() == .alertFirstButtonReturn else { return }
        do {
            var archive = SessionArchive(profiles: currentProfiles, directories: directories, includePasswords: passwords.state == .on, links: links, proxies: current.proxies)
            if passwords.state == .on && hasLocal {
                guard let exportPassword = PasswordVault.promptMaster(title: "设置导出文件密码", creating: true),
                      let keys = try PasswordVault.shared.credentialKeys(for: credentials) else { return }
                let source = archive
                guard let result = CredentialTask.run(title: "加密导出密码…", work: { token in
                    try source.protectedForExport(password: exportPassword, credentialKey: { profile in
                        guard let envelope = profile.encryptedPassword, let key = keys[envelope.ciphertext] else { throw ModelError.invalid("缺少导出所需的解密密钥。"); }; return key
                    }, check: token.check)
                }) else { return }
                archive = try result.get()
            }
            let data = try archive.encoded()
            let panel = NSSavePanel(); panel.title = "导出 OShell 会话"; panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "OShell-sessions.oshell.json"; panel.canCreateDirectories = true
            guard panel.runPopupModal() == .OK, let url = panel.url else { return }
            try PrivateFile.write(data, to: url)
            Dialogs.message("已导出 \(archive.profiles.count) 个会话。" + (archive.passwordCount > 0 ? (hasLocal ? "导入时使用刚设置的导出文件密码；本机密钥没有导出。" : "导入加密密码时请使用此次导出时的主密码。") : "文件未包含已保存密码。"))
        } catch { Dialogs.message("导出失败：\(error.localizedDescription)") }
    }

    static func importSessions(workspace: WorkspaceController, directory: String) {
        let source = PopupAlert(); source.messageText = "选择会话导入来源"
        source.informativeText = "SecureCRT 支持 XML、INI 和 Sessions 目录；Xshell 支持 XSH、ZIP 结构 XTS 和 Sessions 目录。Xshell 可使用原主密码迁移已保存的登录密码，导入前可预览；SecureCRT 密码及自动执行脚本不迁移。"
        source.addButton(withTitle: "选择文件或目录…"); source.addButton(withTitle: "取消")
        let kinds = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        kinds.addItems(withTitles: ["OShell 会话导出（JSON）", "SecureCRT 会话（XML / INI / 目录）", "Xshell 会话（XSH / XTS / ZIP / 目录）"])
        source.accessoryView = kinds
        guard source.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSOpenPanel()
        if kinds.indexOfSelectedItem == 0 {
            panel.title = "导入 OShell 会话"; panel.allowedContentTypes = [.json]
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            guard panel.runPopupModal() == .OK, let url = panel.url else { return }
            importArchive(at: url, workspace: workspace, directory: directory)
        } else {
            let format: ThirdPartySessionFormat = kinds.indexOfSelectedItem == 1 ? .secureCRT : .xshell
            panel.title = "导入 " + format.title + " 会话"; panel.allowedFileTypes = format.extensions
            panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true; panel.resolvesAliases = false
            guard panel.runPopupModal() == .OK else { return }
            importExternal(at: panel.urls, format: format, workspace: workspace, directory: directory)
        }
    }

    static func importExternal(at urls: [URL], format: ThirdPartySessionFormat, workspace: WorkspaceController, directory: String) {
        guard workspace.isSecurityUnlocked else { return }
        guard let result = CredentialTask.run(title: "读取 " + format.title + " 会话…", message: "正在读取并检查会话文件。取消不会修改配置，不会连接服务器。", work: { token in
            try ThirdPartySessionImporter.read(urls, format: format, check: token.check)
        }) else { return }
        do { try importExternalReport(result.get(), format: format, workspace: workspace, directory: directory) }
        catch { Dialogs.message("导入失败，未修改配置：\(error.localizedDescription)") }
    }

    static func importExternalReport(_ report: ThirdPartySessionReport, format: ThirdPartySessionFormat, workspace: WorkspaceController, directory: String) throws {
        let preview = PopupAlert(); preview.messageText = format.title + "：可导入 \(report.profiles.count) 个会话，跳过 \(report.skippedCount) 项"
        preview.informativeText = "目标：" + SessionDirectory.display(directory) + "。新会话保留来源目录层级；可选择只为已导入会话补充空密码。代理、隧道和登录自动化不迁移，导入后不会自动连接。"
        preview.addButton(withTitle: "导入"); preview.addButton(withTitle: "取消")
        preview.buttons.first?.isEnabled = !report.profiles.isEmpty
        let passwords = NSButton(checkboxWithTitle: "迁移 \(report.passwordCount) 项 Xshell 加密密码（需要原 Xshell 主密码）", target: nil, action: nil)
        passwords.identifier = .init("import.xshell.passwords"); passwords.state = report.passwordCount > 0 ? .on : .off
        passwords.isEnabled = format == .xshell && report.passwordCount > 0
        let fillMissing = NSButton(checkboxWithTitle: "仅补充已导入会话的空密码，不新建会话、不覆盖已有密码", target: nil, action: nil)
        fillMissing.identifier = .init("import.xshell.fillMissing"); fillMissing.isEnabled = passwords.isEnabled
        let listing = ThirdPartyImportPreview(report)
        listing.widthAnchor.constraint(equalToConstant: 760).isActive = true
        listing.heightAnchor.constraint(equalToConstant: 340).isActive = true
        let content = NSStackView(views: [passwords, fillMissing, listing])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.frame = NSRect(x: 0, y: 0, width: 760, height: 410)
        preview.accessoryView = content
        guard preview.runModal() == .alertFirstButtonReturn, !report.profiles.isEmpty else { return }
        let include = passwords.isEnabled && passwords.state == .on
        let fillOnly = fillMissing.isEnabled && fillMissing.state == .on
        guard !fillOnly || include else { throw ModelError.invalid("补充密码时请同时勾选迁移 Xshell 加密密码。") }
        let snapshot = workspace.configuration, revision = workspace.configurationRevision
        var importedPasswords = 0, preservedPasswords = 0, unmatched = 0
        let updated: Configuration
        if include {
            guard let sourceMaster = promptXshellMaster() else { return }
            let destinationSecret: String, localID: UUID?
            if snapshot.hasMasterPassword {
                guard let master = PasswordVault.shared.masterForImport(hasSavedPasswords: true) else { return }
                destinationSecret = master; localID = nil
            } else {
                let key = try PasswordVault.shared.localKeyForSaving(knownProfiles: workspace.credentialProfiles)
                destinationSecret = key.secret; localID = key.id
            }
            guard let result = CredentialTask.run(title: "正在迁移 Xshell 密码…", message: "校验原主密码，并重新加密保存。任一密码校验失败或取消时，不写入会话配置。", work: { token in
                try report.importingPasswords(into: snapshot, directory: directory, sourceMaster: sourceMaster,
                                              destinationSecret: destinationSecret, destinationLocalKeyID: localID,
                                              fillMissingOnly: fillOnly, check: token.check)
            }) else { return }
            let value = try result.get(); updated = value.configuration
            importedPasswords = value.importedPasswords; preservedPasswords = value.preservedPasswords; unmatched = value.unmatchedSessions
        } else {
            guard let result = CredentialTask.run(title: "正在导入会话…", message: "正在合并目录和会话。完成后一次性保存；取消不会修改配置。", work: { token in
                try report.archive.merging(into: snapshot, directory: directory, includePasswords: false, check: token.check)
            }) else { return }
            updated = try result.get()
        }
        guard workspace.isSecurityUnlocked, workspace.configurationRevision == revision else { throw ModelError.invalid("处理期间配置已变化或已锁定，请重新导入。") }
        if !fillOnly || importedPasswords > 0 { guard workspace.saveConfiguration(updated) else { return } }
        let summary = fillOnly ? "已补充 \(importedPasswords) 项密码；保留 \(preservedPasswords) 项已有密码；\(unmatched) 个会话未匹配。没有新建会话。" : "已导入 \(report.profiles.count) 个会话，迁移 \(importedPasswords) 项密码，原有会话已保留。"
        Dialogs.message(summary + (include ? "" : "本次未迁移密码。") + "请在连接前核对用户名、私钥、代理及隧道设置。")
    }

    private static func promptXshellMaster() -> String? {
        let alert = PopupAlert(); alert.messageText = "输入原 Xshell 主密码"
        alert.informativeText = "用于解密本次导出的 Xshell 登录密码，不会保存或成为 OShell 主密码。密码将使用 OShell 当前的保护方式重新加密。"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        input.identifier = .init("import.xshell.master"); input.placeholderString = "Xshell 主密码（不是服务器密码）"
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        defer { input.stringValue = "" }
        while alert.runModal() == .alertFirstButtonReturn { if !input.stringValue.isEmpty { return input.stringValue } }
        return nil
    }

    static func importArchive(at url: URL, workspace: WorkspaceController, directory: String) {
        do {
            let archive = try SessionArchive.read(url)
            let preview = PopupAlert(); preview.messageText = "导入 \(archive.profiles.count) 个会话"
            preview.informativeText = "目标：\(directory.isEmpty ? "所有会话" : directory)。保留文件中的目录层级，包括空目录；快捷引用及其目录统一恢复到 /Links。同名会话另存为“导入副本”，现有会话和设置保留。导入后不会自动连接。"
            preview.addButton(withTitle: "导入"); preview.addButton(withTitle: "取消")
            let passwords = NSButton(checkboxWithTitle: "导入 \(archive.passwordCount) 项加密密码", target: nil, action: nil)
            passwords.state = archive.passwordCount > 0 ? .on : .off; passwords.isEnabled = archive.passwordCount > 0
            let protection = NSPopUpButton(); protection.addItems(withTitles: PasswordProtection.allCases.map(\.title))
            protection.selectItem(at: workspace.configuration.hasMasterPassword ? 1 : 0)
            protection.isEnabled = archive.passwordCount > 0
            if workspace.configuration.hasMasterPassword { protection.autoenablesItems = false; protection.item(at: 0)?.isEnabled = false }
            let choices = NSStackView(views: [passwords, protection]); choices.orientation = .vertical; choices.alignment = .leading; choices.spacing = 10
            choices.frame = NSRect(x: 0, y: 0, width: 450, height: 64); preview.accessoryView = choices
            guard preview.runModal() == .alertFirstButtonReturn else { return }
            let include = passwords.state == .on
            var sourceMaster: String?, destinationMaster: String?, destinationLocalKeyID: UUID?
            if include {
                guard let source = PasswordVault.promptMaster(title: "输入导出文件密码或原主密码", creating: false) else { return }
                sourceMaster = source
                if protection.indexOfSelectedItem == 0 {
                    let key = try PasswordVault.shared.localKeyForSaving(knownProfiles: workspace.credentialProfiles)
                    destinationMaster = key.secret; destinationLocalKeyID = key.id
                } else {
                    guard let destination = PasswordVault.shared.masterForImport(hasSavedPasswords: workspace.configuration.hasMasterPassword) else { return }
                    destinationMaster = destination
                }
            }
            let snapshot = workspace.configuration, revision = workspace.configurationRevision
            var localKeys = [String: String]()
            if destinationLocalKeyID == nil, let destinationMaster {
                for profile in ConfigurationCredentials.profiles(in: snapshot) {
                    if let envelope = profile.encryptedPassword, envelope.localKeyID != nil {
                        localKeys[envelope.ciphertext] = try PasswordVault.shared.migrationKey(profile, master: destinationMaster)
                    }
                }
            }
            let migrationKeys = localKeys
            guard let result = CredentialTask.run(title: "正在导入会话…", work: { token in
                var merged = try archive.merging(into: snapshot, directory: directory, includePasswords: include,
                                    sourceMaster: sourceMaster, destinationMaster: destinationMaster, destinationLocalKeyID: destinationLocalKeyID, check: token.check)
                var migration: CredentialRotation?
                if destinationLocalKeyID == nil, let destinationMaster {
                    migration = try MasterPasswordProtection.enabling(merged, password: destinationMaster, credentialKey: { profile in
                        guard let cipher = profile.encryptedPassword?.ciphertext, let key = migrationKeys[cipher] else { throw ModelError.invalid("缺少本机加密密钥。") }
                        return key
                    }, check: token.check)
                    merged = migration!.configuration
                }
                return (merged, migration)
            }) else { return }
            let (updated, migration) = try result.get()
            guard revision == workspace.configurationRevision else { throw ModelError.invalid("处理期间配置已变化，请重新导入。") }
            guard workspace.saveConfiguration(updated, updatingMasterProtection: true) else { return }
            if destinationLocalKeyID == nil, let destinationMaster {
                if let migration { PasswordVault.shared.acceptRotation(migration, master: destinationMaster) }
                else { PasswordVault.shared.acceptMaster(destinationMaster) }
            }
            Dialogs.message("已导入 \(archive.profiles.count) 个会话，原有会话已保留。")
        } catch { Dialogs.message("导入失败，未修改配置：\(error.localizedDescription)") }
    }
}
