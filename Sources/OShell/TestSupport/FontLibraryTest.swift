// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum FontLibraryTest {
    static func run(_ workspace: WorkspaceController) {
        guard let output = ProcessInfo.processInfo.environment["OSHELL_FONT_LIBRARY_OUTPUT"], let fixtures = ProcessInfo.processInfo.environment["OSHELL_TEST_FONT_ROOT"] else { return }
        var checks = [String: Bool]()
        do {
            let store = UserTerminalFonts.library
            checks["freshLibraryEmpty"] = try store.manifest().fonts.isEmpty
            let enumerator = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)
            checks["noFontsInAppBundle"] = !(enumerator?.allObjects as? [URL] ?? []).contains { ["ttf", "otf", "ttc", "otc"].contains($0.pathExtension.lowercased()) }
            let source = URL(fileURLWithPath: fixtures).appendingPathComponent("CascadiaCode/CascadiaCode-Light.ttf")
            try UserTerminalFonts.importFiles([source]); UserTerminalFonts.didChange(scheduleSync: false)
            let first = try store.manifest()
            checks["importedAndRegistered"] = first.fonts.count == 1 && UserTerminalFonts.resolve("CascadiaCode-Light", size: 14)?.fontName == "CascadiaCode-Light"
            checks["onlyAppConfigurationDirectory"] = store.directory.deletingLastPathComponent().path == workspace.store.url.deletingLastPathComponent().path
            var notifications = 0
            let observer = NotificationCenter.default.addObserver(forName: UserTerminalFonts.changed, object: nil, queue: .main) { _ in notifications += 1 }
            try UserTerminalFonts.importFiles([source]); UserTerminalFonts.didChange(scheduleSync: false)
            NotificationCenter.default.removeObserver(observer)
            checks["unchangedFontLibraryDoesNotRefreshTerminals"] = notifications == 0
            checks["duplicateImportDeduplicated"] = try store.manifest() == first
            let picker = NSPopUpButton(); TerminalFontCatalog.populate(picker, selected: "CascadiaCode-Light")
            checks["fontPickerShowsImportedFace"] = picker.selectedItem?.title.hasSuffix("（已导入）") == true
            let invalid = store.directory.appendingPathComponent("invalid.ttf")
            try Data([0,1,0,0] + Array(repeating: 0, count: 32)).write(to: invalid)
            do { try UserTerminalFonts.importFiles([invalid]); checks["coreTextRejectsInvalidFont"] = false } catch { checks["coreTextRejectsInvalidFont"] = true }
            checks["invalidImportPreservesManifest"] = try store.manifest() == first
            try FileManager.default.removeItem(at: invalid)
            try store.commit(FontManifest(), expecting: first); UserTerminalFonts.didChange(scheduleSync: false)
            checks["removedFontFallsBack"] = UserTerminalFonts.resolve("CascadiaCode-Light", size: 14) == nil
            TerminalFontCatalog.populate(picker, selected: "CascadiaCode-Light")
            checks["missingFontChoicePreserved"] = picker.selectedItem?.representedObject as? String == "CascadiaCode-Light"
            checks["missingFontPreviewFallsBack"] = TerminalFontCatalog.previewFont(picker).fontName != "CascadiaCode-Light"
            try UserTerminalFonts.importFiles([source]); UserTerminalFonts.didChange(scheduleSync: false)
            checks["reimportRestoresFont"] = UserTerminalFonts.resolve("CascadiaCode-Light", size: 14)?.fontName == "CascadiaCode-Light"
            let incoming = store.directory.deletingLastPathComponent().appendingPathComponent("import-fixture")
            defer { try? FileManager.default.removeItem(at: incoming) }
            let nested = incoming.appendingPathComponent("nested/deeper")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let duplicate = nested.appendingPathComponent("Light.TTF")
            try FileManager.default.copyItem(at: source, to: duplicate)
            let regular = incoming.appendingPathComponent("Regular.ttf")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixtures).appendingPathComponent("CascadiaCode/CascadiaCode-Regular.ttf"), to: regular)
            try Data("Not a font".utf8).write(to: nested.appendingPathComponent("README.txt"))
            try FileManager.default.createSymbolicLink(at: incoming.appendingPathComponent("loop"), withDestinationURL: incoming)
            try FileManager.default.createSymbolicLink(at: incoming.appendingPathComponent("linked.ttf"), withDestinationURL: source)
            checks["parentDirectoryIncludesAllDescendants"] = try Set(UserTerminalFonts.selectedFontFiles([incoming])) == Set([regular, duplicate])
            let found = try UserTerminalFonts.selectedFontFiles([incoming, nested, duplicate])
            checks["directoryRecursesAndDeduplicatesSelections"] = Set(found) == Set([regular, duplicate])
            checks["singleFileSelectionStillWorks"] = try UserTerminalFonts.selectedFontFiles([source]) == [source]
            let staged = try UserTerminalFonts.stageFiles([incoming, source])
            checks["directoryImportDeduplicatesFontContents"] = staged.merged.fonts.count == 2
            checks["directoryStagingDoesNotActivateFonts"] = try store.manifest().fonts.count == 1
            try store.commit(staged.merged, expecting: staged.before); UserTerminalFonts.didChange(scheduleSync: false)
            checks["directoryFontsBecomeAvailable"] = UserTerminalFonts.resolve("CascadiaCode-Regular", size: 14)?.fontName == "CascadiaCode-Regular"
            let stable = try store.manifest()
            try Data("broken".utf8).write(to: nested.appendingPathComponent("broken.otf"))
            do { try UserTerminalFonts.importFiles([incoming]); checks["invalidDirectoryFontRejected"] = false } catch { checks["invalidDirectoryFontRejected"] = true }
            checks["invalidDirectoryPreservesActiveLibrary"] = try store.manifest() == stable
            do { _ = try UserTerminalFonts.stageFiles([incoming], check: { throw ModelError.invalid("fixture cancelled") }); checks["directoryImportCanCancel"] = false } catch { checks["directoryImportCanCancel"] = true }
            let empty = incoming.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            do { _ = try UserTerminalFonts.stageFiles([empty]); checks["emptyDirectoryReported"] = false } catch { checks["emptyDirectoryReported"] = true }
            let excessive = incoming.appendingPathComponent("excessive")
            try FileManager.default.createDirectory(at: excessive, withIntermediateDirectories: true)
            for index in 0..<65 { try Data().write(to: excessive.appendingPathComponent("\(index).ttf")) }
            do { _ = try UserTerminalFonts.selectedFontFiles([excessive]); checks["directoryCandidateCountBounded"] = false } catch { checks["directoryCandidateCountBounded"] = true }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                if let root = NSApp.modalWindow?.contentView {
                    let buttons = descendants(root).compactMap { $0 as? NSButton }
                    checks["manageFontsEntry"] = buttons.contains { $0.title == "管理字体…" }
                    buttons.first { $0.identifier?.rawValue == "settings.navigation.storage" }?.performClick(nil)
                    let checkbox = descendants(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "sync.policy.fonts" }
                    checks["syncFontsDefaultOff"] = checkbox?.state == .off
                } else { checks["settingsOpened"] = false }
                NSApp.abortModal()
            }
            RunLoop.main.add(timer, forMode: .modalPanel); workspace.showPreferences(); timer.invalidate()
        } catch { checks["unexpectedError"] = false; NSLog("Font fixture: %@", error.localizedDescription) }
        try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
