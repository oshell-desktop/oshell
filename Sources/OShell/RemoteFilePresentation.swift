// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

/// A filename hint only: never downloads a remote file or changes how it is opened.
enum RemoteFileKind: String, CaseIterable {
    case directory = "目录", link = "符号链接", unknown = "未知"
    case file = "文件", text = "文本", code = "代码", script = "脚本", configuration = "配置"
    case archive = "压缩包", image = "图片", audio = "音频", video = "视频", pdf = "PDF"
    case document = "文档", spreadsheet = "表格", presentation = "演示文稿"
    case database = "数据库", package = "安装包", font = "字体", certificate = "证书 / 密钥"

    init(_ entry: RemoteFileEntry) {
        // Server metadata takes priority over misleading suffixes (e.g. a folder named a.zip).
        if entry.symbolicLink { self = .link; return }
        if entry.unknownType { self = .unknown; return }
        if entry.directory { self = .directory; return }
        let name = entry.name.lowercased(), ext = (entry.name as NSString).pathExtension.lowercased()
        if ["dockerfile", "makefile", "gnumakefile", "cmakelists.txt", "jenkinsfile", "vagrantfile"].contains(name) { self = .code; return }
        if [".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile"].contains(name) { self = .script; return }
        if [".env", ".gitignore", ".gitattributes", ".editorconfig", ".npmrc", ".vimrc", "config", "known_hosts", "authorized_keys"].contains(name) || name.hasPrefix(".env.") { self = .configuration; return }
        if ["readme", "license", "licence", "copying", "changelog", "authors", "notice"].contains(name) { self = .text; return }
        switch ext {
        case "txt", "log", "md", "markdown", "rst", "rtf": self = .text
        case "swift", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt", "scala", "js", "jsx", "ts", "tsx", "vue", "html", "htm", "css", "scss", "sql": self = .code
        case "sh", "bash", "zsh", "fish", "py", "rb", "pl", "lua", "php", "ps1", "bat", "cmd": self = .script
        case "json", "jsonc", "yaml", "yml", "toml", "ini", "conf", "config", "cfg", "xml", "plist", "properties", "service", "env": self = .configuration
        case "zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "zst", "7z", "rar", "lz", "lz4", "jar", "war": self = .archive
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "icns", "heic", "tif", "tiff", "bmp", "avif": self = .image
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff": self = .audio
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "mpeg": self = .video
        case "pdf": self = .pdf
        case "doc", "docx", "odt", "pages": self = .document
        case "xls", "xlsx", "csv", "tsv", "ods", "numbers": self = .spreadsheet
        case "ppt", "pptx", "odp": self = .presentation
        case "db", "sqlite", "sqlite3", "mdb": self = .database
        case "dmg", "pkg", "deb", "rpm", "msi", "exe", "apk", "iso": self = .package
        case "ttf", "otf", "woff", "woff2": self = .font
        case "pem", "crt", "cer", "key", "p12", "pfx", "pub": self = .certificate
        default: self = .file
        }
    }

    private var symbol: String {
        switch self {
        case .directory: return "folder.fill"
        case .link: return "link"
        case .unknown: return "questionmark.square"
        case .file: return "doc"
        case .text: return "doc.text"
        case .code: return "chevron.left.slash.chevron.right"
        case .script: return "terminal"
        case .configuration: return "gearshape"
        case .archive: return "archivebox.fill"
        case .image: return "photo"
        case .audio: return "music.note"
        case .video: return "film"
        case .pdf, .document: return "doc.richtext"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .database: return "externaldrive"
        case .package: return "shippingbox"
        case .font: return "textformat"
        case .certificate: return "key.fill"
        }
    }
    var color: NSColor {
        switch self {
        case .directory, .code, .document, .font: return .systemBlue
        case .link, .image, .video: return .systemPurple
        case .script, .spreadsheet, .database: return .systemGreen
        case .archive, .package, .presentation, .certificate: return .systemOrange
        case .pdf, .audio: return .systemRed
        default: return .secondaryLabelColor
        }
    }
    // One image per category bounds cache size even for directories containing thousands of extensions.
    private static var images: [RemoteFileKind: NSImage] = [:]
    var icon: NSImage {
        if let cached = Self.images[self] { return cached }
        let image: NSImage
        if let symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: rawValue) {
            image = symbol
        } else {
            // Native type icons also work on the oldest supported macOS, without SF Symbols.
            let types: [RemoteFileKind: String] = [.directory: "public.folder", .link: "public.symlink", .unknown: "public.item", .file: "public.data", .text: "txt", .code: "public.source-code", .script: "sh", .configuration: "plist", .archive: "zip", .image: "png", .audio: "mp3", .video: "mov", .pdf: "pdf", .document: "doc", .spreadsheet: "xls", .presentation: "ppt", .database: "sqlite", .package: "pkg", .font: "ttf", .certificate: "cer"]
            image = NSWorkspace.shared.icon(forFileType: types[self] ?? "public.data")
        }
        Self.images[self] = image
        return image
    }
}

final class RemoteFileNameCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("remoteFileName")
    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        let icon = NSImageView(), label = NSTextField(labelWithString: "")
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        imageView = icon; textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ entry: RemoteFileEntry) {
        let kind = RemoteFileKind(entry)
        textField?.stringValue = entry.name
        imageView?.image = kind.icon
        imageView?.contentTintColor = kind.color
        imageView?.setAccessibilityLabel(kind.rawValue)
        toolTip = "\(entry.name)\n\(kind.rawValue)" + (kind == .unknown ? "（服务器未提供类型）" : "")
    }
}
