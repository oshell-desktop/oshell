// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum SessionPasswordEditingTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func field(_ editor: SessionEditor, _ id: String) -> NSTextField {
            descendants(editor.dialog.accessoryView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id }!
        }
        func input(_ editor: SessionEditor) -> PasswordEntryView {
            descendants(editor.dialog.accessoryView!).compactMap { $0 as? PasswordEntryView }.first!
        }
        func finishEditor(_ editor: SessionEditor, save: Bool) -> SessionProfile? {
            var failed = false
            let timer = Timer(timeInterval: 0.08, repeats: true) { _ in
                if NSApp.modalWindow === editor.dialog.window { editor.dialog.buttons[save && !failed ? 0 : 1].performClick(nil) }
                else if let window = NSApp.modalWindow { failed = true; _ = PopupKeyboard.dismiss(window: window) }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            let result = editor.run(); checks["noUnexpectedValidationAlert"] = (checks["noUnexpectedValidationAlert"] ?? true) && !failed
            return result
        }
        let secret = "copy-fixture-'\"--中文🔐", replacement = "replacement-fixture-'\"--"
        do {
            let prefix = "user#UTF-8#2437#SSH#"
            for (label, login) in [("full", prefix + "root"), ("prefix", prefix)] {
                let editor = SessionEditor(nil, profiles: [], directories: [], initialDirectory: "", localMode: .bastion)
                func edit(_ id: String, _ value: String) {
                    let control = field(editor, id)
                    control.stringValue = value
                    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: control)
                }
                edit("session.host", "127.0.0.1")
                edit("session.user", login)
                checks[label + "InitialAccount"] = field(editor, "session.targetAccount").stringValue == (label == "full" ? "root" : "")
                edit("session.targetPassword", replacement)
                if label == "prefix" {
                    for value in ["r", "ro", "roo", "root"] { edit("session.targetAccount", value) }
                }
                checks[label + "CompleteName"] = finishEditor(editor, save: true)?.username == prefix + "root"
                if case .replace(let saved)? = editor.targetChange { checks[label + "TargetPassword"] = saved == replacement }
                else { checks[label + "TargetPassword"] = false }
            }
            for mode in [PasswordProtection.local, .master] {
                PasswordVault.shared.unlockForTesting("copy-fixture-master")
                for kind in [SessionKind.ssh, .sftp, .ftp] {
                    let label = "\(mode)-\(kind)"
                    var source = SessionProfile(name: label, kind: kind, host: "192.0.2.10", port: kind == .ftp ? 21 : 22, username: "fixture")
                    source.encryptedPassword = try PasswordVault.shared.protect(secret, profile: source, knownProfiles: workspace.credentialProfiles, protection: mode, identity: SSHIdentity(host: source.host, user: source.username, port: source.port))
                    var config = workspace.configuration; config.profiles.append(source); _ = workspace.saveConfiguration(config)
                    guard let copy = workspace.duplicateSavedSession(source.id) else { checks[label+"Copy"] = false; continue }
                    checks[label+"CopyKeepsPassword"] = try PasswordVault.shared.readSavedPassword(copy) == secret && copy.id != source.id
                    let editor = SessionEditor(copy, profiles: workspace.credentialProfiles, directories: [], initialDirectory: "")
                    let password = input(editor)
                    checks[label+"SavedNeverPrefilled"] = password.stringValue.isEmpty && !password.isRevealed
                    password.revealButton.performClick(nil)
                    checks[label+"SavedCannotBeRevealed"] = password.visibleField.stringValue.isEmpty && password.secureField.stringValue.isEmpty
                    password.clear()
                    field(editor,"session.host").stringValue = "192.0.2.20"
                    field(editor,"session.port").stringValue = kind == .ftp ? "2121" : "2222"
                    field(editor,"session.user").stringValue = "other-fixture"
                    guard let changed = finishEditor(editor,save:true) else { checks[label+"Save"] = false; continue }
                    checks[label+"ChangedTargetKeepsPassword"] = try PasswordVault.shared.readSavedPassword(changed) == secret
                    checks[label+"EnvelopeRebound"] = changed.encryptedPassword?.identity == SSHIdentity(host: changed.host,user: changed.username,port: changed.port) && changed.encryptedPassword != copy.encryptedPassword
                    checks[label+"SourceIntact"] = workspace.configuration.profiles.first { $0.id == source.id } == source
                    var newConfig = workspace.configuration; let index = newConfig.profiles.firstIndex { $0.id == changed.id }!; newConfig.profiles[index] = changed
                    _ = workspace.saveConfiguration(newConfig)
                    let restored = try workspace.store.load().profiles.first { $0.id == changed.id }!
                    checks[label+"DiskRoundTrip"] = try PasswordVault.shared.readSavedPassword(restored) == secret
                    let reopened = SessionEditor(restored, profiles: workspace.credentialProfiles, directories: [], initialDirectory: "")
                    checks[label+"ReopenMaskedAndEmpty"] = !input(reopened).isRevealed && input(reopened).stringValue.isEmpty
                    input(reopened).stringValue = replacement; input(reopened).revealButton.performClick(nil)
                    checks[label+"NewInputVisible"] = input(reopened).visibleField.stringValue == replacement && input(reopened).secureField.stringValue.isEmpty
                    if let replaced = finishEditor(reopened,save:true) {
                        checks[label+"NewInputReplacesPassword"] = try PasswordVault.shared.readSavedPassword(replaced) == replacement
                    } else { checks[label+"NewInputReplacesPassword"] = false }
                    checks[label+"ClosedClearsBothFields"] = input(reopened).secureField.stringValue.isEmpty && input(reopened).visibleField.stringValue.isEmpty && !input(reopened).isRevealed
                    let cleared = SessionEditor(restored, profiles: workspace.credentialProfiles, directories: [], initialDirectory: "")
                    descendants(cleared.dialog.accessoryView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "session.remember" }!.state = .off
                    checks[label+"UncheckRemovesPassword"] = finishEditor(cleared,save:true)?.encryptedPassword == nil
                    let cancel = SessionEditor(restored, profiles: workspace.credentialProfiles, directories: [], initialDirectory: "")
                    input(cancel).stringValue = replacement; input(cancel).revealButton.performClick(nil)
                    checks[label+"CancelDiscardsDraft"] = finishEditor(cancel,save:false) == nil && input(cancel).stringValue.isEmpty && !input(cancel).isRevealed
                }
            }
            let disk = String(decoding: try Data(contentsOf: workspace.store.url),as:UTF8.self)
            checks["NoPlaintextOnDisk"] = !disk.contains("copy-fixture-") && !disk.contains("replacement-fixture-")
        } catch { checks["unexpectedError"] = false }

        let entry = PasswordEntryView(identifier:"fixture.password")
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:26),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = entry; window.makeKeyAndOrderFront(nil)
        entry.stringValue = secret; window.makeFirstResponder(entry.secureField)
        (entry.secureField.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location:2,length:3))
        entry.revealButton.performClick(nil)
        let text = entry.visibleField.currentEditor() as? NSTextView
        checks["TogglePreservesTextAndSelection"] = text?.string == secret && text?.selectedRange() == NSRange(location:2,length:3)
        checks["RevealedInputDisablesSmartPunctuation"] = text?.isAutomaticQuoteSubstitutionEnabled == false && text?.isAutomaticDashSubstitutionEnabled == false && text?.isAutomaticTextReplacementEnabled == false
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.control,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{1}",charactersIgnoringModifiers:"a",isARepeat:false,keyCode:0)!
        checks["RevealedControlA"] = PopupKeyboard.selectAllPassword(with:event,in:window) && text?.selectedRange().length == (secret as NSString).length
        text?.insertText(replacement,replacementRange:NSRange(location:NSNotFound,length:0))
        entry.revealButton.performClick(nil)
        checks["HidePreservesEditedValue"] = entry.stringValue == replacement && entry.visibleField.stringValue.isEmpty
        entry.clear(); checks["ClearResetsVisibility"] = entry.secureField.stringValue.isEmpty && entry.visibleField.stringValue.isEmpty && !entry.isRevealed
        window.close()
        let report: [String:Any] = ["passed":checks.values.allSatisfy { $0 },"checks":checks]
        if let output = ProcessInfo.processInfo.environment["OSHELL_SESSION_PASSWORD_OUTPUT"] { try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output)) }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
