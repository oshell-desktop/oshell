// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public enum InterfaceTheme: String, Codable, CaseIterable {
    case system, light, dark
    public var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
}

public struct TerminalColorScheme: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var background: String
    public var foreground: String
    public var boldForeground: String?
    public var cursor: String
    public var cursorText: String
    public var autoCursor = false
    public var selection: String
    public var selectionText: String
    public var ansi: [String]
    public init(id: String, name: String, background: String, foreground: String, cursor: String? = nil, selection: String, selectionText: String? = nil, ansi: [String]) {
        self.id = id; self.name = name; self.background = background; self.foreground = foreground
        self.cursor = cursor ?? foreground; cursorText = background
        self.selection = selection; self.selectionText = selectionText ?? foreground; self.ansi = ansi
    }
    private enum CodingKeys: String, CodingKey {case id,name,background,foreground,boldForeground,cursor,cursorText,autoCursor,selection,selectionText,ansi}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name)
        background=try c.decode(String.self,forKey:.background);foreground=try c.decode(String.self,forKey:.foreground)
        boldForeground = try c.decodeIfPresent(String.self, forKey: .boldForeground)
        cursor=try c.decode(String.self,forKey:.cursor);cursorText=try c.decode(String.self,forKey:.cursorText)
        selection=try c.decode(String.self,forKey:.selection);selectionText=try c.decode(String.self,forKey:.selectionText)
        ansi=try c.decode([String].self,forKey:.ansi);autoCursor=try c.decodeIfPresent(Bool.self,forKey:.autoCursor) ?? false
    }
    public static func isHex(_ value: String) -> Bool {
        value.utf8.count == 7 && value.first == "#" && value.utf8.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
    public var isDark: Bool {
        guard let value = UInt32(background.dropFirst(), radix: 16) else { return true }
        let red = Double((value >> 16) & 255)
        let green = Double((value >> 8) & 255)
        let blue = Double(value & 255)
        return red * 0.2126 + green * 0.7152 + blue * 0.0722 < 128
    }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), ansi.count == 16,
              boldForeground.map(Self.isHex) ?? true,
              ([background, foreground, cursor, cursorText, selection, selectionText] + ansi).allSatisfy(Self.isHex) else {
            throw ModelError.invalid("配色方案需要有效名称、6 个基础颜色及 16 个 ANSI 颜色（#RRGGBB）。")
        }
    }
    public func editableCopy() -> TerminalColorScheme {
        var result = self; result.id = "custom-" + UUID().uuidString; result.name = String(name.prefix(72)) + " · 自定义"; return result
    }
    public static let ansiNames = ["黑", "红", "绿", "黄", "蓝", "紫", "青", "白"]
    private static let classic = ["#000000", "#C23621", "#25BC24", "#ADAD27", "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD", "#818383", "#FC391F", "#31E722", "#EAEC23", "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB"]
    private static let tango = ["#2E3436", "#CC0000", "#4E9A06", "#C4A000", "#3465A4", "#75507B", "#06989A", "#D3D7CF", "#555753", "#EF2929", "#8AE234", "#FCE94F", "#729FCF", "#AD7FA8", "#34E2E2", "#EEEEEC"]
    private static let solarized = ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5", "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
    public static let presets: [TerminalColorScheme] = [
        .init(id: "oshell-dark", name: "OShell 深色", background: "#11151A", foreground: "#E3E3E3", cursor: "#55E5CC", selection: "#00A6B2", selectionText: "#000000", ansi: classic),
        .init(id: "oshell-light", name: "OShell 浅色", background: "#FBFBFB", foreground: "#1F1F1F", cursor: "#008C83", selection: "#C3DFE8", selectionText: "#17212B", ansi: classic),
        .init(id: "graphite-flame", name: "石墨 · 焰橙", background: "#171D26", foreground: "#E6EAF0", cursor: "#FF8550", selection: "#594536", selectionText: "#FFF3E8", ansi: ["#252D39", "#FF6B62", "#9BCE86", "#F2C66D", "#82AFF5", "#CA9FE6", "#7ACFD1", "#D2D8E2", "#768394", "#FF9189", "#B6E2A2", "#FFD990", "#A5C7FF", "#DFC0F4", "#A3E3E4", "#F7F8FA"]),
        .init(id: "solarized-dark", name: "Solarized Dark", background: "#002B36", foreground: "#839496", selection: "#073642", selectionText: "#93A1A1", ansi: solarized),
        .init(id: "solarized-light", name: "Solarized Light", background: "#FDF6E3", foreground: "#657B83", selection: "#EEE8D5", selectionText: "#586E75", ansi: solarized),
        .init(id: "dracula-xshell", name: "Dracula · Xshell", background: "#1E1F29", foreground: "#F8F8F2", cursor: "#FF79C6", selection: "#44475A", ansi: ["#555555", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#FFFFFF", "#000000", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#BBBBBB"]),
        .init(id: "nord", name: "Nord", background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E", selectionText: "#ECEFF4", ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0", "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]),
        .init(id: "tango-dark", name: "Tango 深色", background: "#2E3436", foreground: "#D3D7CF", selection: "#555753", selectionText: "#FFFFFF", ansi: tango),
        .init(id: "tango-light", name: "Tango 浅色", background: "#FFFFFF", foreground: "#2E3436", cursor: "#3465A4", selection: "#C7D8EC", selectionText: "#20252A", ansi: tango)
    ]
    public static func decodeImport(_ data: Data) throws -> [TerminalColorScheme] {
        guard data.count <= 65536 else { throw ModelError.invalid("配色文件不能超过 64 KiB。"); }
        if let one = try? JSONDecoder().decode(TerminalColorScheme.self, from: data) { try one.validate(); return [one.editableCopy()] }
        guard let text = String(data: data, encoding: .utf8) ?? (data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) ? String(data: data, encoding: .utf16) : nil) else {
            throw ModelError.invalid("配色文件应为 OShell JSON 或 UTF-8/UTF-16 Xshell .xcs。");
        }
        var sections: [(String, [String: String])] = []
        for raw in text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { sections.append((String(line.dropFirst().dropLast()), [:])) }
            else if let equal = line.firstIndex(of: "="), !sections.isEmpty {
                let key = line[..<equal].trimmingCharacters(in: .whitespaces).lowercased()
                sections[sections.count - 1].1[key] = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let keys = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var result = [TerminalColorScheme]()
        for (name, fields) in sections where name.lowercased() != "names" {
            func hex(_ key: String) throws -> String {
                guard let raw = fields[key] else { throw ModelError.invalid("Xshell 配色缺少 \(key)。"); }
                let value = (raw.hasPrefix("#") ? raw : "#" + raw).uppercased()
                guard isHex(value) else { throw ModelError.invalid("Xshell 颜色格式无效：\(key)。"); }; return value
            }
            let bg = try hex("background"), fg = try hex("text")
            var scheme = TerminalColorScheme(id: "custom-" + UUID().uuidString, name: name, background: bg, foreground: fg,
                                             selection: "#405A78", selectionText: "#FFFFFF", ansi: try (keys + keys.map { $0 + "(bold)" }).map(hex))
            if fields["text(bold)"] != nil {
                scheme.boldForeground = try hex("text(bold)")
            }
            if !scheme.isDark { scheme.selection = "#C7D8EC"; scheme.selectionText = "#20252A" }
            try scheme.validate(); result.append(scheme)
        }
        guard !result.isEmpty, result.count <= 64 else { throw ModelError.invalid("未找到有效配色方案，或方案超过 64 个。"); }
        return result
    }
}
