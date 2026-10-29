// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreText
import UniformTypeIdentifiers
import OShellCore

/// Main-thread registration cache. Files stay app-private, never in ~/Library/Fonts.
enum UserTerminalFonts {
    struct Face { let name: String, title: String }
    static let changed = Notification.Name("OShellUserFontsChanged")
    static var library: FontLibrary { FontLibrary(configurationDirectory: (try? StorageLocation.resolvedDirectory()) ?? StorageLocation.localStateDirectory) }
    private static var current: FontManifest?, facesByFile = [String: [Face]](), owned = Set<String>(), retired = Set<String>()
    private(set) static var generation = 0
    private(set) static var error: String?
    static var faces: [Face] { register(); return facesByFile.keys.sorted().flatMap { facesByFile[$0] ?? [] } }
    static func descriptors(_ url: URL) throws -> [Face] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty, descriptors.count <= 128 else { throw ModelError.invalid("文件不是有效的 TTF / OTF 字体或字体集合。") }
        return try descriptors.map { descriptor in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, !name.isEmpty else { throw ModelError.invalid("字体缺少 PostScript 名称。") }
            let title = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String ?? name
            return Face(name: name, title: title)
        }
    }
    static func validate(_ url: URL) throws { _ = try descriptors(url) }
    static func register() {
        do {
            let next = try library.manifest(); guard next != current else { return }
            var entries = [String: [Face]]()
            for asset in next.fonts {
                if let cached = facesByFile[asset.name] { entries[asset.name] = cached; continue }
                _ = try library.data(asset); let url = library.url(asset), faces = try descriptors(url)
                entries[asset.name] = faces
            }
            for asset in current?.fonts ?? [] where entries[asset.name] == nil {
                if owned.remove(asset.name) != nil {
                    retired.formUnion(facesByFile[asset.name]?.map(\.name) ?? [])
                    CTFontManagerUnregisterFontsForURL(library.url(asset) as CFURL, .process, nil)
                }
            }
            for asset in next.fonts where !owned.contains(asset.name) {
                if CTFontManagerRegisterFontsForURL(library.url(asset) as CFURL, .process, nil) { owned.insert(asset.name) }
            }
            retired.subtract(entries.values.flatMap { $0.map(\.name) })
            facesByFile = entries; current = next; generation += 1; error = nil
        } catch { self.error = error.localizedDescription }
    }
    static func resolve(_ name: String, size: CGFloat) -> NSFont? {
        register(); return name.isEmpty || retired.contains(name) ? nil : NSFont(name: name, size: size)
    }
    static func didChange(scheduleSync: Bool = true) {
        let previous = generation
        register()
        guard generation != previous else { return }
        NotificationCenter.default.post(name: changed, object: scheduleSync)
    }
    static func importFiles(_ urls: [URL]) throws {
        let staged = try stageFiles(urls)
        try library.commit(staged.merged, expecting: staged.before)
    }
    /// Enumerate incrementally on the import worker; never follow directory links.
    static func selectedFontFiles(_ selections: [URL], check: () throws -> Void = {}) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        var seen = Set<URL>(), files = [URL]()
        func inspect(_ input: URL, explicit: Bool = false) throws -> Bool {
            try check()
            let url = input.standardizedFileURL
            guard !seen.contains(url) else { return false }
            guard seen.count < 10_000 else { throw ModelError.invalid("目录内容过多，请选择更具体的字体文件夹。") }
            seen.insert(url)
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true || values.isPackage == true {
                if explicit { throw ModelError.invalid("请选择实际字体文件或普通目录，不支持快捷替身、符号链接或应用包。") }
                return false
            }
            if values.isDirectory == true { return true }
            if values.isRegularFile == true, ["ttf", "otf", "ttc", "otc"].contains(url.pathExtension.lowercased()) {
                guard files.count < 64 else { throw ModelError.invalid("每次最多导入 64 个字体文件，请缩小选择范围。") }
                files.append(url)
            } else if explicit { throw ModelError.invalid("请选择字体目录，或 TTF、OTF、TTC、OTC 字体文件。") }
            return false
        }
        for selection in selections {
            guard try inspect(selection, explicit: true) else { continue }
            var traversalError: Error?
            guard let items = FileManager.default.enumerator(at: selection, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                traversalError = error; return false
            }) else { throw ModelError.invalid("无法读取所选字体目录。") }
            while let item = items.nextObject() as? URL {
                // Calling skipDescendants after a regular file can skip the
                // next directory on macOS; only prune actual directory entries.
                if try !inspect(item), try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    items.skipDescendants()
                }
            }
            if let traversalError { throw traversalError }
        }
        guard !files.isEmpty else { throw ModelError.invalid("所选目录中没有可导入的字体文件（TTF / OTF / TTC / OTC）。") }
        return files.sorted { $0.path < $1.path }
    }
    static func stageFiles(_ urls: [URL], check: () throws -> Void = {}) throws -> (before: FontManifest, merged: FontManifest) {
        let urls = try selectedFontFiles(urls, check: check)
        let store = library, before = try store.manifest()
        var assets = Set(before.fonts)
        for url in urls {
            try check()
            let type = url.pathExtension.lowercased()
            guard ["ttf", "otf", "ttc", "otc"].contains(type) else { throw ModelError.invalid("请选择 TTF、OTF、TTC 或 OTC 字体文件。") }
            guard let data = try SharedDataFile.readIfPresent(url, maximumSize: FontLibrary.maximumFileSize) else { throw ModelError.invalid("字体文件不存在。") }
            let asset = FontAsset(data: data, fileExtension: type); try asset.verify(data)
            // Validate the copied bytes, not a source URL that may change after selection.
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], !descriptors.isEmpty, descriptors.count <= 128 else { throw ModelError.invalid("无法解析字体文件，未更改字体库。") }
            assets.insert(asset); try FontManifest(fonts: Array(assets)).validate()
            try store.store(data, asset: asset)
        }
        try check(); return (before, FontManifest(fonts: Array(assets)))
    }
}

final class UserFontManager: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var fonts = [FontAsset](), titles = [String]()
    private let status = AppUI.label("", secondary: true)
    private var remove: NSButton!
    func run() {
        let alert = PopupAlert(); alert.messageText = "管理导入字体"; alert.informativeText = "字体保存在配置目录的 fonts 文件夹，只供 OShell 使用。导入和移除立即保存；终端字体选择仍需在设置页点击“应用”。"
        alert.addButton(withTitle: "完成")
        let root = InterfaceSurfaceView(frame: NSRect(x: 0, y: 0, width: 680, height: 390))
        for (id, title, width) in [("name", "字体", 480.0), ("size", "大小", 120.0)] { let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column) }
        table.delegate = self; table.dataSource = self; table.rowHeight = 30
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; AppUI.styleScrollSurface(scroll)
        let add = AppUI.button("导入字体…", symbol: "plus", primary: true) { [weak self] in self?.importFonts() }
        remove = AppUI.button("移除所选字体", symbol: "minus") { [weak self] in self?.removeFont() }
        let folder = AppUI.button("打开字体目录", symbol: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: UserTerminalFonts.library.directory.path) }
        let bar = AppUI.row([add, remove, NSView(), folder])
        for view in [scroll, bar, status] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -14), bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor), bar.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12), status.leadingAnchor.constraint(equalTo: root.leadingAnchor), status.trailingAnchor.constraint(equalTo: root.trailingAnchor), status.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        alert.accessoryView = root; reload(); alert.runModal()
    }
    private func reload() {
        do {
            fonts = try UserTerminalFonts.library.manifest().fonts
            titles = fonts.map { asset in (try? UserTerminalFonts.descriptors(UserTerminalFonts.library.url(asset)).map(\.title).joined(separator: " · ")) ?? asset.name }
            status.stringValue = "\(fonts.count) 个字体文件 · 单文件 ≤ 20 MiB，总计 ≤ 64 MiB。同步需在“多设备同步”中勾选“字体文件”。"
        } catch { status.stringValue = error.localizedDescription }
        table.reloadData(); remove?.isEnabled = table.selectedRow >= 0
    }
    func numberOfRows(in tableView: NSTableView) -> Int { fonts.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: column?.identifier.rawValue == "name" ? titles[row] : ByteCountFormatter.string(fromByteCount: Int64(fonts[row].size), countStyle: .file)); label.lineBreakMode = .byTruncatingTail; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { remove?.isEnabled = table.selectedRow >= 0 }
    private func importFonts() {
        let panel = NSOpenPanel(); panel.title = "导入字体文件或目录"; panel.prompt = "导入"
        panel.allowsMultipleSelection = true; panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.resolvesAliases = false
        panel.message = "可多选字体文件或目录；目录包含子目录，自动忽略非字体文件、隐藏项目和符号链接。"
        panel.allowedContentTypes = [.folder] + ["ttf", "otf", "ttc", "otc"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runPopupModal() == .OK else { return }; let urls = panel.urls
        guard let result = CredentialTask.run(title: "正在验证并导入字体…", message: "正在扫描目录并验证字体；取消不会改变当前字体库。", work: { token in try UserTerminalFonts.stageFiles(urls, check: token.check) }) else { return }
        do { let staged = try result.get(); try UserTerminalFonts.library.commit(staged.merged, expecting: staged.before); UserTerminalFonts.didChange(); reload() } catch { Dialogs.message(error.localizedDescription) }
    }
    private func removeFont() {
        guard fonts.indices.contains(table.selectedRow) else { return }; let asset = fonts[table.selectedRow]
        guard Dialogs.confirm("移除所选字体？", text: "使用该字体的终端会临时回退到系统字体。历史清单和文件保留在字体目录，便于恢复；开启字体同步后会同步移除选择。", action: "移除") else { return }
        do {
            let store = UserTerminalFonts.library, before = try store.manifest()
            try store.commit(FontManifest(fonts: before.fonts.filter { $0 != asset }), expecting: before)
            UserTerminalFonts.didChange(); reload()
        } catch { Dialogs.message(error.localizedDescription) }
    }
}
