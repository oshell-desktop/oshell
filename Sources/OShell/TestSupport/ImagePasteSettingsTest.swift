// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum ImagePasteSettingsTest {
    static func run(_ workspace: WorkspaceController) throws -> [String: Bool] {
        var checks = [String: Bool]()
        var profile = SessionProfile(name: "Fixture", host: "image.example.test", username: "ops")
        let binding = ImagePasteSettings.binding(profile)
        var settings = ImagePasteSettings()
        checks["imagesDefaultToConfirmation"] = !settings.skipLocalConfirmation && settings.remote.isEmpty
        settings.remote[ImagePasteSettings.key(profile)] = .init(binding: binding, directory: "/tmp/project images", title: "Fixture")
        try settings.save()
        checks["remoteChoicePersists"] = try ImagePasteSettings.load().remoteRule(for: profile, binding: binding)?.directory == "/tmp/project images"
        checks["remoteChoiceDoesNotSuppressLocal"] = !settings.skipLocalConfirmation
        var copy = profile; copy.id = UUID()
        checks["copiedSessionAsksAgain"] = settings.remoteRule(for: copy, binding: binding) == nil
        for (name, edit) in [
            ("host", { (p: inout SessionProfile) in p.host = "another.example.test" }),
            ("port", { (p: inout SessionProfile) in p.port = 2222 }),
            ("user", { (p: inout SessionProfile) in p.username = "other" }),
            ("jump", { (p: inout SessionProfile) in p.jumpHost = "gateway.example.test" }),
            ("proxy", { (p: inout SessionProfile) in p.proxy.kind = .jump; p.proxy.host = "gateway.example.test" })
        ] {
            var changed = profile; edit(&changed)
            checks["changedTargetAsksAgain." + name] = settings.remoteRule(for: changed, binding: ImagePasteSettings.binding(changed)) == nil
        }
        profile.name = "Renamed"
        checks["renameKeepsRememberedChoice"] = ImagePasteSettings.binding(profile) == binding
        let encoded = try Data(contentsOf: ImagePasteSettings.url)
        checks["imageSettingsPrivateFile"] = (try FileManager.default.attributesOfItem(atPath: ImagePasteSettings.url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
        checks["imageSettingsContainNoCredentials"] = !String(decoding: encoded, as: UTF8.self).contains("encryptedPassword")
        var unsupported = settings; unsupported.version = 99; try unsupported.save()
        do { _ = try ImagePasteSettings.load(); checks["unknownImageSettingsRejected"] = false } catch { checks["unknownImageSettingsRejected"] = true }
        try settings.save()
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        // Exercise the real outer settings transaction, including cancellation.
        func editSettings(apply: Bool) {
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                guard let outer = NSApp.modalWindow?.contentView,
                      let manage = views(outer).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "settings.imagePaste.manage" }) else {
                    checks["imageSettingsEntryExists"] = false; NSApp.abortModal(); return
                }
                checks["imageSettingsEntryExists"] = true
                let answer = Timer(timeInterval: 0.05, repeats: false) { _ in
                    guard let inner = NSApp.modalWindow?.contentView else { return }
                    let buttons = views(inner).compactMap { $0 as? NSButton }
                    buttons.first { $0.identifier?.rawValue == "paste.settings.local" }?.state = .on
                    buttons.first { $0.identifier?.rawValue.hasPrefix("paste.settings.remote.") == true }?.state = .off
                    buttons.first { $0.title == "确定" }?.performClick(nil)
                }
                RunLoop.main.add(answer, forMode: .modalPanel)
                manage.performClick(nil)
                checks["imagePreferenceDraftDoesNotSaveEarly"] = (try? ImagePasteSettings.load()) == settings
                views(outer).compactMap { $0 as? NSButton }.first { $0.title == (apply ? "应用" : "取消") }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            workspace.showPreferences()
        }
        editSettings(apply: false)
        checks["cancelPreservesImagePreferences"] = try ImagePasteSettings.load() == settings
        editSettings(apply: true)
        let changed = try ImagePasteSettings.load()
        checks["applyCanSuppressLocalAndRestoreRemote"] = changed.skipLocalConfirmation && changed.remote.isEmpty
        try ImagePasteSettings().save()
        return checks
    }
}
