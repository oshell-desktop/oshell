// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ImageIO
import Darwin
import OShellCore

struct TerminalClipboardImage {
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumSourceBytes = 160 * 1024 * 1024
    let png: Data
    let width: Int
    let height: Int

    static func read(_ clipboard: NSPasteboard) throws -> Self? {
        // Finder also supplies icon/thumbnail representations for non-image files.
        // Never mistake those for an image the user intended to attach.
        if clipboard.types?.contains(.fileURL) == true {
            let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let extensions = ["png", "jpg", "jpeg", "tif", "tiff", "gif", "webp", "heic", "bmp"]
            if urls.count > 1, urls.contains(where: { extensions.contains($0.pathExtension.lowercased()) }) { throw ModelError.invalid("请一次粘贴一张图片。") }
            guard urls.count == 1, let url = urls.first, extensions.contains(url.pathExtension.lowercased()) else { return nil }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= maximumBytes else { throw ModelError.invalid("图片文件过大或不可读取，单张最多 20 MiB。") }
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            return try decode(file.read(upToCount: maximumBytes + 1) ?? Data())
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, .init("public.jpeg")] {
            if let data = clipboard.data(forType: type) { return try decode(data) }
        }
        return nil
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 40_000_000 else {
            throw ModelError.invalid("剪贴板图片无效或过大（原始数据最多 160 MiB、4000 万像素；转换后的 PNG 最多 20 MiB）。")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ModelError.invalid("无法解码剪贴板图片。") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw ModelError.invalid("无法转换图片。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { throw ModelError.invalid("转换后的 PNG 超过 20 MiB，请缩小图片后重试。") }
        return .init(png: output as Data, width: image.width, height: image.height)
    }
}

enum TerminalClipboardFiles {
    static var directory: URL { StorageLocation.localStateDirectory.appendingPathComponent("clipboard-images", isDirectory: true) }
    static func save(_ image: TerminalClipboardImage) throws -> URL {
        let root = directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw ModelError.invalid("图片缓存目录权限无效，请检查本机数据目录。")
        }
        var used = 0
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]) {
            guard url.lastPathComponent.hasPrefix("oshell-clipboard-"), url.pathExtension == "png",
                  let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                  value.isRegularFile == true, value.isSymbolicLink != true else { continue }
            if let date = value.contentModificationDate, date < cutoff { try FileManager.default.removeItem(at: url) }
            else { used += value.fileSize ?? 0 }
        }
        guard used + image.png.count <= 200 * 1024 * 1024 else { throw ModelError.invalid("图片缓存已达 200 MiB，请清理本机数据目录中的 clipboard-images 后重试。") }
        let url = root.appendingPathComponent("oshell-clipboard-" + UUID().uuidString.lowercased() + ".png")
        try PrivateFile.write(image.png, to: url)
        return url
    }
    /// Backslash escaping is understood by shells and both Codex/OpenCode path parsers.
    static func pastedPath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ModelError.invalid("图片路径包含无效字符。") }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.:+")
        return path.unicodeScalars.map { safe.contains($0) ? String($0) : "\\" + String($0) }.joined()
    }
}
