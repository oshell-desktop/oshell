// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

/// In-memory editor for OShell's command launcher, not a shell or a PTY reader.
/// Passwords entered after launching SSH are handled by that PTY, never here.
struct LocalPromptInput {
    private enum Escape { case none, start, searchEnd, csi, ss3, string, stringEscape }
    private var escape = Escape.none, sequence = [UInt8](), utf8 = [UInt8]()
    private var line = [Character](), cursor = 0, bytesUsed = 0, start = 0
    private var history = [String](), historyIndex: Int?, draft = ""
    private var overflow = false, afterReturn = false
    private let limit = 8192
    private struct Search {
        var query = ""
        var index: Int?
        var failed = false
        var tooLong = false
    }
    private var search: Search?
    private var killed = ""
    var isEmptyForReconnect: Bool { line.isEmpty && utf8.isEmpty && !overflow && search == nil && escape == .none }

    // Searching does not mutate the draft. Ctrl+G can restore its exact cursor,
    // history navigation position and overflow state without a second snapshot.
    private mutating func searchHistory(older: Bool = true, repeatSearch: Bool = false) {
        guard var state = search else { return }
        if state.tooLong { state.failed = true; search = state; return }
        let anchor = state.index ?? (older ? history.count : -1)
        let first = repeatSearch ? anchor + (older ? -1 : 1) : min(anchor, history.count - 1)
        let candidates = older ? Array(stride(from: first, through: 0, by: -1))
                               : Array(stride(from: first, to: history.count, by: 1))
        if let found = candidates.first(where: { history.indices.contains($0) && history[$0].contains(state.query) }) {
            state.index = found; state.failed = false
        } else { state.failed = true }
        search = state
    }
    private mutating func finishSearch(accept: Bool) {
        guard let state = search else { return }
        if accept, !state.failed, let index = state.index {
            if historyIndex == nil { draft = String(line) }
            replace(history[index]); historyIndex = index
        }
        search = nil; utf8.removeAll()
    }
    private func searchDisplay(columns: Int) -> [UInt8] {
        guard let state = search else { return [] }
        // Keep the search prompt on one row, including on narrow split panes.
        let label = columns >= 60 ? (state.failed ? "(failed reverse-i-search)`" : "(reverse-i-search)`")
                                  : (state.failed ? "R? `" : "R `")
        let capacity = max(1, columns - label.count - 5)
        let queryBudget = max(1, capacity / 2)
        var query = [Character](), used = 0
        for c in state.query.reversed() {
            if used + width(c) > queryBudget { break }
            query.insert(c, at: 0); used += width(c)
        }
        let candidate = state.failed ? "" : state.index.map { history[$0] } ?? ""
        var preview = "", remaining = capacity - used
        for c in candidate {
            if width(c) > remaining { break }
            preview.append(c); remaining -= width(c)
        }
        return Array(("\r\u{1b}[2K" + label + String(query) + "\u{1b}7': " + preview + "\u{1b}8").utf8)
    }
    private func wordStart() -> Int {
        var position = cursor
        while position > 0 && line[position - 1].isWhitespace { position -= 1 }
        while position > 0 && !line[position - 1].isWhitespace { position -= 1 }
        return position
    }
    private func wordEnd() -> Int {
        var position = cursor
        while position < line.count && line[position].isWhitespace { position += 1 }
        while position < line.count && !line[position].isWhitespace { position += 1 }
        return position
    }
    private mutating func kill(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        killed = String(line[range]); line.removeSubrange(range)
        cursor = range.lowerBound; start = min(start, cursor)
        bytesUsed = String(line).utf8.count
        if line.isEmpty { overflow = false }
    }
    private mutating func insertText(_ value: String) {
        guard bytesUsed + value.utf8.count <= limit else { return }
        for scalar in value.unicodeScalars { insert(scalar) }
    }
    private mutating func completeCommand() -> [UInt8] {
        // Only complete the executable name; do not interpret paths or arguments.
        guard line[..<cursor].allSatisfy({ !$0.isWhitespace }),
              cursor == line.count || line[cursor].isWhitespace else { return [7] }
        let prefix = String(line[..<cursor])
        let matches = (LocalToolCommand.names + ["help", "tools", "exit", "quit"]).sorted().filter { $0.hasPrefix(prefix) }
        guard let first = matches.first else { return [7] }
        if matches.count == 1 {
            insertText(String(first.dropFirst(prefix.count)) + (cursor == line.count ? " " : ""))
            return []
        }
        let shared = matches.dropFirst().reduce(Array(first)) { result, item in
            Array(zip(result, Array(item)).prefix(while: { $0.0 == $0.1 }).map { $0.0 })
        }
        if shared.count > prefix.count { insertText(String(shared.dropFirst(prefix.count))); return [] }
        return Array(("\r\n" + matches.joined(separator: "  ") + "\r\n").utf8)
    }
    // ASCII is one cell; other graphemes reserve at most two cells. This
    // conservative viewport avoids wraps without guessing the renderer's exact
    // Unicode width. Save/restore positions the cursor using real terminal cells.
    private func width(_ character: Character) -> Int { character.isASCII ? 1 : 2 }
    private mutating func redraw(columns: Int) -> [UInt8] {
        if search != nil { return searchDisplay(columns: columns) }
        let capacity = max(1,columns-EndedSessionInput.prompt.count-2)
        start = min(start,cursor)
        var prefixWidth = line[start..<cursor].reduce(0,{ $0+width($1) })
        while start < cursor && prefixWidth >= capacity { prefixWidth -= width(line[start]); start += 1 }
        var end = start, used = 0
        while end < line.count && used+width(line[end]) <= capacity { used += width(line[end]); end += 1 }
        let before = String(line[start..<cursor]), after = String(line[cursor..<max(cursor,end)])
        return Array(("\r\u{1b}[2K"+EndedSessionInput.prompt+before+"\u{1b}7"+after+"\u{1b}8").utf8)
    }
    private mutating func insert(_ scalar: UnicodeScalar) {
        if (0x80...0x9f).contains(scalar.value) { insert("\u{fffd}"); return }
        let value = String(scalar)
        if var state = search {
            guard !state.tooLong, state.query.utf8.count + value.utf8.count <= limit else {
                state.tooLong = true; state.failed = true; search = state; return
            }
            state.query += value; search = state; searchHistory()
            return
        }
        guard bytesUsed+value.utf8.count <= limit else { overflow = true; return }
        bytesUsed += value.utf8.count
        if cursor > 0, !scalar.isASCII {
            let joined = Array(String(line[cursor-1])+value)
            if joined.count == 1 { line[cursor-1] = joined[0]; return }
        }
        line.insert(Character(value),at:cursor); cursor += 1
    }
    private mutating func textByte(_ byte: UInt8) {
        if utf8.isEmpty {
            if byte < 128 { insert(UnicodeScalar(byte)); return }
            if !(0xc2...0xf4).contains(byte) { insert("\u{fffd}"); return }
        } else if !(0x80...0xbf).contains(byte) {
            utf8.removeAll(); insert("\u{fffd}"); textByte(byte); return
        }
        utf8.append(byte)
        let needed = utf8[0] < 0xe0 ? 2 : (utf8[0] < 0xf0 ? 3 : 4)
        if utf8.count == needed {
            if let text = String(bytes:utf8,encoding:.utf8), let scalar = text.unicodeScalars.first { insert(scalar) }
            else { insert("\u{fffd}") }
            utf8.removeAll()
        }
    }
    private mutating func replace(_ value:String) {
        line = Array(value); cursor = line.count; bytesUsed = value.utf8.count; start = 0; overflow = false; utf8.removeAll()
    }
    private mutating func navigateHistory(_ older:Bool) {
        guard !history.isEmpty else { return }
        if older {
            if historyIndex == nil { draft = String(line); historyIndex = history.count }
            historyIndex = max(0,(historyIndex ?? history.count)-1)
            replace(history[historyIndex!])
        } else if let index = historyIndex {
            if index+1 < history.count { historyIndex = index+1; replace(history[index+1]) }
            else { historyIndex = nil; replace(draft); draft = "" }
        }
    }
    private mutating func escapeCommand(_ final:UInt8) {
        let parameter = String(decoding:sequence,as:UTF8.self)
        switch final {
        case 65: navigateHistory(true)
        case 66: navigateHistory(false)
        case 67: cursor = ["1;3", "1;5"].contains(parameter) ? wordEnd() : min(line.count,cursor+1)
        case 68: cursor = ["1;3", "1;5"].contains(parameter) ? wordStart() : max(0,cursor-1)
        case 72: cursor = 0; start = 0
        case 70: cursor = line.count
        case 126:
            if ["1","7"].contains(parameter) { cursor = 0; start = 0 }
            if ["4","8"].contains(parameter) { cursor = line.count }
            if parameter == "3", cursor < line.count { bytesUsed -= String(line.remove(at:cursor)).utf8.count }
        default: break
        }
    }
    mutating func consume(_ input:ArraySlice<UInt8>, columns:Int) -> EndedSessionInput.Result {
        var echo = [UInt8](), dirty = false
        for index in input.indices {
            let byte = input[index]
            switch escape {
            case .searchEnd:
                // Esc accepts a search without consuming the next typed letter;
                // still recognize arrows when Esc is their sequence prefix.
                escape = .none
                if byte == 91 { sequence.removeAll(); escape = .csi; continue }
                if byte == 79 { sequence.removeAll(); escape = .ss3; continue }
            case .start:
                sequence.removeAll()
                escape = .none
                switch byte {
                case 91: escape = .csi
                case 79: escape = .ss3
                case 93,80,94,95: escape = .string
                case 98: cursor = wordStart(); dirty = true
                case 102: cursor = wordEnd(); dirty = true
                case 100: kill(cursor..<wordEnd()); dirty = true
                case 8,127: kill(wordStart()..<cursor); dirty = true
                default: break
                }
                continue
            case .csi:
                if (0x40...0x7e).contains(byte) { escapeCommand(byte); escape = .none; dirty = true }
                else if sequence.count < 32 { sequence.append(byte) }
                else { sequence = [255] } // Never accumulate unbounded escape input.
                continue
            case .ss3: escapeCommand(byte); escape = .none; dirty = true; continue
            case .string:
                if byte == 7 { escape = .none } else if byte == 27 { escape = .stringEscape }; continue
            case .stringEscape: escape = byte == 92 ? .none : .string; continue
            case .none: break
            }
            if byte == 10 && afterReturn { afterReturn = false; continue }
            afterReturn = byte == 13
            if byte < 32 || byte == 127 {
                if !utf8.isEmpty { utf8.removeAll(); insert("\u{fffd}"); dirty = true }
            }
            if search != nil {
                switch byte {
                case 18: searchHistory(repeatSearch: true); dirty = true; continue
                case 19: searchHistory(older: false, repeatSearch: true); dirty = true; continue
                case 7: finishSearch(accept: false); dirty = true; continue
                case 27: finishSearch(accept: true); escape = .searchEnd; dirty = true; continue
                case 8,127:
                    if var state = search, !state.query.isEmpty {
                        state.query.removeLast(); state.index = nil; state.tooLong = false; search = state; searchHistory()
                    }
                    dirty = true; continue
                case 12: echo += Array("\u{1b}[2J\u{1b}[H".utf8); dirty = true; continue
                case 32...126,128...255: textByte(byte); dirty = true; continue
                case 13,10:
                    // A failed search must never execute a stale, unrelated match.
                    if search?.failed == true { echo.append(7); dirty = true; continue }
                    finishSearch(accept: true)
                default: finishSearch(accept: byte != 3)
                }
            }
            switch byte {
            case 18: search = Search(); searchHistory(); dirty = true
            case 27: escape = .start
            case 1: cursor = 0; start = 0; dirty = true
            case 5: cursor = line.count; dirty = true
            case 2: cursor = max(0,cursor-1); dirty = true
            case 6: cursor = min(line.count,cursor+1); dirty = true
            case 16: navigateHistory(true); dirty = true
            case 14: navigateHistory(false); dirty = true
            case 8,127:
                if cursor > 0 { cursor -= 1; bytesUsed -= String(line.remove(at:cursor)).utf8.count; dirty = true }
            case 4:
                if line.isEmpty && !overflow { return .init(echo: echo, close: true) }
                if cursor < line.count { bytesUsed -= String(line.remove(at:cursor)).utf8.count; dirty = true }
            case 11: kill(cursor..<line.count); dirty = true
            case 21:
                kill(0..<cursor); if line.isEmpty { overflow = false }; dirty = true
            case 23: kill(wordStart()..<cursor); dirty = true
            case 25: insertText(killed); dirty = true
            case 12: echo += Array("\u{1b}[2J\u{1b}[H".utf8); dirty = true
            case 20:
                if cursor > 0 && line.count > 1 {
                    let right = min(cursor, line.count - 1)
                    line.swapAt(right - 1, right); cursor = right + 1; dirty = true
                }
            case 3:
                replace(""); historyIndex = nil; draft = ""; echo += Array(("^C\r\n"+EndedSessionInput.prompt).utf8); dirty = false
            case 9: echo += completeCommand(); dirty = true
            case 13,10:
                let full = String(line), raw = full.trimmingCharacters(in:.whitespaces), lower = raw.lowercased(), tooLong = overflow
                echo += Array(("\r\u{1b}[2K"+EndedSessionInput.prompt+full+"\r\n").utf8)
                replace(""); historyIndex = nil; draft = ""; dirty = false
                if tooLong { echo += Array("命令过长，未执行。\r\n".utf8) }
                else if lower == "exit" || lower == "quit" { return .init(echo:echo,close:true) }
                else if !raw.isEmpty {
                    if history.last != full { history.append(full); if history.count > 100 { history.removeFirst() } }
                    if lower == "help" || lower == "?" { echo += Array((LocalToolCommand.help+"\r\n").utf8) }
                    else if lower == "tools" { echo += Array((LocalToolCommand.availability()+"\r\n").utf8) }
                    else {
                        do { return .init(echo:echo,close:false,command:try LocalToolCommand.parse(raw),remaining:Array(input[input.index(after:index)...])) }
                        catch { echo += Array((error.localizedDescription+"\r\n").utf8) }
                    }
                }
                echo += Array(EndedSessionInput.prompt.utf8)
            case 32...126,128...255: textByte(byte); dirty = true
            default: break
            }
        }
        if dirty { echo += redraw(columns:columns) }
        return .init(echo:echo,close:false)
    }
}
