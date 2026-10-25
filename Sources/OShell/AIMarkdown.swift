// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Local, bounded Markdown presentation. No HTML importer, web view, script,
/// attachment loader, or network request is involved in rendering a reply.
enum AIMarkdown {
    enum Block {
        case text(NSAttributedString)
        case code(language: String, source: String, closed: Bool)
    }
    static func safeLink(_ value: String) -> URL? {
        guard value.count <= 4096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: value), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
    private static func match(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (0..<found.numberOfRanges).map { Range(found.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
    }
    private static func destination(_ source: String) -> String {
        if source.hasPrefix("<"), let end = source.firstIndex(of: ">") { return String(source[source.index(after: source.startIndex)..<end]) }
        // An optional Markdown link title is presentation, not part of the URL.
        return String(source.prefix(while: { !$0.isWhitespace }))
    }
    private static func fence(_ line: String) -> (marker: Character, count: Int, language: String)? {
        let text = line.drop(while: { $0 == " " })
        guard line.count - text.count <= 3, let marker = text.first, marker == "`" || marker == "~" else { return nil }
        let count = text.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = String(text.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        guard marker != "`" || !info.contains("`") else { return nil }
        return (marker, count, String(info.split(whereSeparator: \.isWhitespace).first ?? "").lowercased())
    }
    private static func closes(_ line: String, _ opening: (marker: Character, count: Int, language: String)) -> Bool {
        let text = line.drop(while: { $0 == " " })
        guard line.count - text.count <= 3 else { return false }
        let count = text.prefix(while: { $0 == opening.marker }).count
        return count >= opening.count && text.dropFirst(count).allSatisfy(\.isWhitespace)
    }
    private static func cells(_ line: String) -> [String] {
        var result = [String](), cell = "", escaped = false, codeRun = 0
        let chars = Array(line.trimmingCharacters(in: .whitespaces)); var i = 0
        while i < chars.count {
            let char = chars[i]
            if escaped { cell.append(char); escaped = false; i += 1; continue }
            if char == "\\" { cell.append(char); escaped = true; i += 1; continue }
            if char == "`" {
                var end = i; while end < chars.count && chars[end] == "`" { end += 1 }
                let count = end - i; if codeRun == 0 { codeRun = count } else if codeRun == count { codeRun = 0 }
                cell += String(repeating: "`", count: count); i = end; continue
            }
            if char == "|" && codeRun == 0 { result.append(cell); cell = "" } else { cell.append(char) }
            i += 1
        }
        result.append(cell)
        if result.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeFirst() }
        if result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeLast() }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func tableAlignments(_ line: String) -> [NSTextAlignment]? {
        let values = cells(line)
        guard line.contains("|"), !values.isEmpty, values.count <= 12,
              values.allSatisfy({ match("^:?-{3,}:?$", $0) != nil }) else { return nil }
        return values.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .right) : .left }
    }
    private static func heading(_ line: String) -> [String]? { match("^ {0,3}(#{1,6})[ \\t]+(.+?)(?:[ \\t]+#+)?[ \\t]*$", line) }
    private static func list(_ line: String) -> [String]? { match("^( *)([-+*]|[0-9]{1,9}[.)])[ \\t]+(.+)$", line) }
    private static func rule(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces).filter { !$0.isWhitespace }
        return text.count >= 3 && ["-", "*", "_"].contains(text.first.map(String.init) ?? "") && Set(text).count == 1
    }
    /// Repair only unmistakable prose boundaries from double-escaped model JSON.
    /// Never unescape code spans/fences, paths, regexes or executable source.
    static func readableProse(_ source: String) -> String {
        let protected = try! NSRegularExpression(pattern: #"(`{3,}|~{3,})[\s\S]*?(?:\1|$)|`+[^`]*(?:`+|$)"#)
        let breaks = try! NSRegularExpression(pattern: #"(?:\\n){2,}|\\n(?=(?:[-*+] |#{1,6} |\*\*|> |[0-9]+[.)] ))"#)
        let ns = source as NSString
        func repair(_ value: String) -> String {
            let result = NSMutableString(string: value)
            for match in breaks.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length)).reversed() {
                result.replaceCharacters(in: match.range, with: String(repeating: "\n", count: match.range.length / 2))
            }
            return result as String
        }
        var result = "", offset = 0
        for match in protected.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            result += repair(ns.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            result += ns.substring(with: match.range); offset = NSMaxRange(match.range)
        }
        return result + repair(ns.substring(from: offset))
    }
    static func blocks(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var result = [Block](), prose = NSMutableAttributedString(string: ""), i = 0
        func flush() { if prose.length > 0 { result.append(.text(prose)); prose = NSMutableAttributedString(string: "") } }
        func append(_ text: String, font: NSFont = .systemFont(ofSize: 13), style: NSMutableParagraphStyle = NSMutableParagraphStyle(), color: NSColor = .labelColor) {
            style.lineSpacing = 3; style.paragraphSpacing = 8
            let value = inline(text, font: font, color: color)
            value.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: color]))
            value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length)); prose.append(value)
        }
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if let opening = fence(line) {
                flush(); i += 1; var content = [String]()
                while i < lines.count && !closes(lines[i], opening) { content.append(lines[i]); i += 1 }
                let closed = i < lines.count; if closed { i += 1 }
                result.append(.code(language: opening.language, source: content.joined(separator: "\n"), closed: closed)); continue
            }
            if i + 1 < lines.count, let alignments = tableAlignments(lines[i + 1]), cells(line).count == alignments.count {
                var rows = [cells(line)]; i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = cells(lines[i]); guard row.count == alignments.count else { break }
                    rows.append(row); i += 1
                }
                prose.append(table(rows, alignments: alignments)); continue
            }
            if let values = heading(line) {
                let size: CGFloat = [22, 19, 16, 14, 13, 13][values[1].count - 1]
                append(values[2], font: .systemFont(ofSize: size, weight: .semibold)); i += 1; continue
            }
            if i + 1 < lines.count, match("^ {0,3}(=+|-+)[ \\t]*$", lines[i + 1]) != nil, list(line) == nil {
                append(line, font: .systemFont(ofSize: lines[i + 1].contains("=") ? 22 : 19, weight: .semibold)); i += 2; continue
            }
            if rule(line) { append("────────────", color: .gridColor); i += 1; continue }
            if let item = list(line) {
                let style = NSMutableParagraphStyle(), indent = CGFloat(min(12, item[1].count)) * 5
                style.firstLineHeadIndent = indent; style.headIndent = indent + 22
                var content = item[3], marker = Int(item[2].dropLast()) == nil ? "•" : item[2]
                if content.hasPrefix("[ ] ") { marker = "☐"; content = String(content.dropFirst(4)) }
                else if content.lowercased().hasPrefix("[x] ") { marker = "☑"; content = String(content.dropFirst(4)) }
                append(marker + "  " + content, style: style); i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                var quote = [String]()
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                let style = NSMutableParagraphStyle(); style.firstLineHeadIndent = 8; style.headIndent = 18
                append("▎ " + quote.joined(separator: "\n"), style: style, color: .secondaryLabelColor); continue
            }
            if line.hasPrefix("    ") || line.hasPrefix("\t") {
                flush(); var content = [String]()
                while i < lines.count && (lines[i].hasPrefix("    ") || lines[i].hasPrefix("\t")) {
                    content.append(String(lines[i].dropFirst(lines[i].hasPrefix("\t") ? 1 : 4))); i += 1
                }
                result.append(.code(language: "", source: content.joined(separator: "\n"), closed: true)); continue
            }
            var paragraph = [line]; i += 1
            while i < lines.count {
                let next = lines[i], trimmed = next.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || fence(next) != nil || heading(next) != nil || list(next) != nil || rule(next) || trimmed.hasPrefix(">") || (i + 1 < lines.count && tableAlignments(lines[i + 1]) != nil) { break }
                paragraph.append(next); i += 1
            }
            // Retain explicit line breaks from terminal-oriented model answers.
            append(paragraph.joined(separator: "\n"))
        }
        flush(); return result
    }
    private static func table(_ rows: [[String]], alignments: [NSTextAlignment]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: ""), table = NSTextTable()
        table.numberOfColumns = alignments.count; table.layoutAlgorithm = .fixedLayoutAlgorithm; table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setContentWidth(100 / CGFloat(alignments.count), type: .percentageValueType)
                block.setWidth(5, type: .absoluteValueType, for: .padding); block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(.gridColor); block.backgroundColor = row == 0 ? .controlBackgroundColor : .textBackgroundColor
                let style = NSMutableParagraphStyle(); style.textBlocks = [block]; style.alignment = alignments[column]; style.lineSpacing = 2
                let text = inline(value, font: .systemFont(ofSize: 12, weight: row == 0 ? .semibold : .regular))
                text.append(NSAttributedString(string: "\n")); text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
                result.append(text)
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])); return result
    }
    static func inline(_ source: String, font: NSFont = .systemFont(ofSize: 13), color: NSColor = .labelColor, depth: Int = 0) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: ""), attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        guard depth < 8 else { return NSMutableAttributedString(string: source, attributes: attributes) }
        var index = source.startIndex
        func append(_ text: String) { result.append(NSAttributedString(string: text, attributes: attributes)) }
        while index < source.endIndex {
            let remaining = source[index...], char = source[index], next = source.index(after: index)
            if char == "\\", next < source.endIndex, "\\`*_{}[]()#+-.!|>~".contains(source[next]) { append(String(source[next])); index = source.index(after: next); continue }
            if char == "`" {
                let count = remaining.prefix(while: { $0 == "`" }).count, marker = String(repeating: "`", count: remaining.prefix(while: { $0 == "`" }).count)
                let start = source.index(index, offsetBy: count)
                if let end = source.range(of: marker, range: start..<source.endIndex) {
                    let code = String(source[start..<end.lowerBound]).replacingOccurrences(of: "\n", with: " ")
                    result.append(NSAttributedString(string: code, attributes: [.font: NSFont.oshellMonospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), .foregroundColor: color, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.14)]))
                    index = end.upperBound; continue
                }
            }
            let image = remaining.hasPrefix("![")
            if char == "[" || image {
                let labelStart = source.index(index, offsetBy: image ? 2 : 1)
                if let end = source.range(of: "](", range: labelStart..<source.endIndex) {
                    var cursor = end.upperBound, nesting = 1, escaped = false
                    while cursor < source.endIndex {
                        let c = source[cursor]
                        if !escaped { if c == "(" { nesting += 1 }; if c == ")" { nesting -= 1 }; if nesting == 0 { break } }
                        escaped = c == "\\" && !escaped; cursor = source.index(after: cursor)
                    }
                    if nesting == 0 {
                        let label = String(source[labelStart..<end.lowerBound]), destination = String(source[end.upperBound..<cursor]).trimmingCharacters(in: .whitespaces)
                        let url = safeLink(Self.destination(destination))
                        let text = image ? NSMutableAttributedString(string: "[图片：" + label + (url == nil ? "]" : " · 点击查看]"), attributes: attributes) : inline(label, font: font, color: color, depth: depth + 1)
                        if let url { text.addAttribute(.link, value: url, range: NSRange(location: 0, length: text.length)) }
                        result.append(text); index = source.index(after: cursor); continue
                    }
                }
            }
            if char == "<", let end = source[next...].firstIndex(of: ">"), let url = safeLink(String(source[next..<end])) {
                result.append(NSAttributedString(string: url.absoluteString, attributes: [.font: font, .foregroundColor: NSColor.linkColor, .link: url])); index = source.index(after: end); continue
            }
            var formatted = false
            for marker in ["***", "___", "**", "__", "~~", "*", "_"] where remaining.hasPrefix(marker) {
                let start = source.index(index, offsetBy: marker.count)
                guard start < source.endIndex, !source[start].isWhitespace else { continue }
                // Underscores inside identifiers such as server_name stay literal.
                if marker.first == "_", index > source.startIndex, source[source.index(before: index)].isLetter || source[source.index(before: index)].isNumber { continue }
                guard let end = source.range(of: marker, range: start..<source.endIndex), end.lowerBound > start,
                      !source[source.index(before: end.lowerBound)].isWhitespace else { continue }
                var traits: NSFontTraitMask = []
                if marker.count >= 2 && marker != "~~" { traits.insert(.boldFontMask) }
                if marker.count == 1 || marker.count == 3 { traits.insert(.italicFontMask) }
                let nested = inline(String(source[start..<end.lowerBound]), font: NSFontManager.shared.convert(font, toHaveTrait: traits), color: color, depth: depth + 1)
                if marker == "~~" { nested.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: nested.length)) }
                result.append(nested); index = end.upperBound; formatted = true; break
            }
            if formatted { continue }
            append(String(char)); index = next
        }
        return result
    }
}

/// Native selectable text, sized from TextKit at the actual panel width. Works
/// on macOS 10.13 as well as modern systems without a separate renderer process.
final class AIMarkdownTextView: NSTextView, NSTextViewDelegate {
    private let ownedStorage = NSTextStorage()
    private var measuredWidth: CGFloat = 0, measuredHeight: CGFloat = 20
    init(_ text: NSAttributedString) {
        let container = NSTextContainer(containerSize: NSSize(width: 376, height: CGFloat.greatestFiniteMagnitude)), manager = NSLayoutManager()
        ownedStorage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 20), textContainer: container)
        isEditable = false; isSelectable = true; isRichText = true; drawsBackground = false
        isVerticallyResizable = false; isHorizontallyResizable = false
        textContainerInset = NSSize(width: 2, height: 2); textContainer?.lineFragmentPadding = 0
        textStorage?.setAttributedString(text); delegate = self
        isAutomaticLinkDetectionEnabled = false; isAutomaticDataDetectionEnabled = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        setContentCompressionResistancePriority(.required, for: .vertical)
        identifier = .init("ai.markdown.text")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize {
        let width = max(1, bounds.width - 4)
        if abs(width - measuredWidth) > 0.5, let container = textContainer, let manager = layoutManager {
            measuredWidth = width; container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            manager.ensureLayout(for: container); measuredHeight = max(20, ceil(manager.usedRect(for: container).maxY) + 4)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }
    override func setFrameSize(_ size: NSSize) {
        let changed = abs(size.width - frame.width) > 0.5; super.setFrameSize(size)
        if changed { invalidateIntrinsicContentSize() }
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let value = (link as? URL)?.absoluteString ?? (link as? String ?? "")
        if let url = AIMarkdown.safeLink(value) { NSWorkspace.shared.open(url) }
        return true // Never let AppKit open arbitrary file:, javascript:, or app URLs.
    }
}
