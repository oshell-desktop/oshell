// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum ImagePasteTest {
    static func sample() throws -> TerminalClipboardImage {
        let image = NSImage(size: NSSize(width: 16, height: 12), flipped: false) { rect in NSColor.systemOrange.setFill(); NSBezierPath(rect: rect).fill(); return true }
        return try TerminalClipboardImage.decode(image.tiffRepresentation!)
    }
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy
        }
        var ownedChange = clipboard.changeCount
        func write(_ data: Data, type: NSPasteboard.PasteboardType) { clipboard.clearContents(); clipboard.setData(data, forType: type); ownedChange = clipboard.changeCount }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func answer(_ title: String) {
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView else { checks["pasteDialogPresented"] = false; return }
                checks["pasteDialogPresented"] = true
                views(root).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func finish() {
            if clipboard.changeCount == ownedChange { clipboard.clearContents(); clipboard.writeObjects(saved) }
            if let path = ProcessInfo.processInfo.environment["OSHELL_IMAGE_PASTE_OUTPUT"] { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        do {
            let image = try sample()
            checks["normalizesImageToPNG"] = image.width == 16 && image.height == 12 && image.png.prefix(8) == Data([137,80,78,71,13,10,26,10])
            do { _ = try TerminalClipboardImage.decode(Data("invalid image".utf8)); checks["invalidRejected"] = false } catch { checks["invalidRejected"] = true }
            do { _ = try TerminalClipboardImage.decode(Data(count: TerminalClipboardImage.maximumBytes + 1)); checks["invalidLargeInputRejected"] = false } catch { checks["invalidLargeInputRejected"] = true }
            try autoreleasepool {
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2500, pixelsHigh: 2200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw ModelError.invalid("Missing TIFF fixture") }
                bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                let tiff = bitmap.tiffRepresentation!
                let decoded = try TerminalClipboardImage.decode(tiff)
                checks["retinaTIFFLargerThan20MiBConverts"] = tiff.count > TerminalClipboardImage.maximumBytes && decoded.width == 2500 && decoded.height == 2200 && decoded.png.count < TerminalClipboardImage.maximumBytes
            }
            checks["shellSpecialCharactersEscaped"] = try TerminalClipboardFiles.pastedPath("/tmp/a b;$x.png") == "/tmp/a\\ b\\;\\$x.png"
            do { _ = try TerminalClipboardFiles.pastedPath("/tmp/bad\nname.png"); checks["controlPathRejected"] = false } catch { checks["controlPathRejected"] = true }
            let isolated = NSPasteboard(name: .init("OShell.ImagePaste." + UUID().uuidString)); defer { isolated.releaseGlobally() }
            isolated.setString("plain text", forType: .string)
            checks["textHasNoImage"] = try TerminalClipboardImage.read(isolated) == nil
            let file = try TerminalClipboardFiles.save(image)
            let fileInfo = try FileManager.default.attributesOfItem(atPath: file.path)
            let dirInfo = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
            checks["privateCachePermissions"] = (fileInfo[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (dirInfo[.posixPermissions] as? NSNumber)?.intValue == 0o700
            isolated.clearContents(); isolated.writeObjects([file as NSURL])
            checks["finderImageRecognized"] = try TerminalClipboardImage.read(isolated)?.width == 16
            isolated.clearContents(); isolated.writeObjects([file.deletingPathExtension().appendingPathExtension("txt") as NSURL]); isolated.setData(image.png, forType: .png)
            checks["nonImageFileIconIgnored"] = try TerminalClipboardImage.read(isolated) == nil
            try FileManager.default.removeItem(at: file)
            workspace.newLocal(); let first = workspace.selectedTab!.activePane
            workspace.newLocal(); let second = workspace.selectedTab!.activePane
            let deadline = Date().addingTimeInterval(10)
            func checkReady() {
                if !first.acceptsManagedInput || !second.acceptsManagedInput || first.receivedBytes == 0 || second.receivedBytes == 0 {
                    if Date() > deadline { checks["localReady"] = false; finish(); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: checkReady); return
                }
                checks["localReady"] = true
                workspace.syncTargets = [first.id, second.id]
                write(image.png, type: .png)
                let before = (try? FileManager.default.contentsOfDirectory(atPath: TerminalClipboardFiles.directory.path)) ?? []
                answer("取消"); first.terminal.paste(first.terminal)
                checks["cancelDoesNotSave"] = ((try? FileManager.default.contentsOfDirectory(atPath: TerminalClipboardFiles.directory.path)) ?? []) == before
                let otherBytes = second.receivedBytes
                answer("保存图片并粘贴路径"); first.terminal.paste(first.terminal)
                let after = (try? FileManager.default.contentsOfDirectory(atPath: TerminalClipboardFiles.directory.path)) ?? []
                let created = after.filter { !before.contains($0) }
                checks["pasteSavesOneImage"] = created.count == 1
                if let name = created.first {
                    let url = TerminalClipboardFiles.directory.appendingPathComponent(name)
                    checks["savedImageMatchesClipboard"] = (try? Data(contentsOf: url)) == image.png
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let rendered = String(decoding: first.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                        checks["pathReachedSourcePTY"] = rendered.contains(name)
                        checks["imagePasteNotBroadcast"] = second.receivedBytes == otherBytes
                        checks["pasteDoesNotSubmitCommand"] = !rendered.contains("permission denied") && !rendered.contains("command not found")
                        finish()
                    }
                } else { finish() }
            }
            checkReady()
        } catch { checks["unexpectedError"] = false; print("Image paste fixture:", error.localizedDescription); finish() }
    }
}
