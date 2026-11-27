// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftTerm

/// Real AppKit mouse events against the same terminal view used by SSH, with
/// synthetic output only. Does not write to the user's clipboard or connect SSH.
enum TerminalDragSelectionTest {
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let output = ProcessInfo.processInfo.environment["OSHELL_DRAG_SELECTION_OUTPUT"], let window = workspace.window else { return }
            var checks = [String: Bool]()
            let clipboardGeneration = NSPasteboard.general.changeCount
            workspace.configuration.preferences.copyOnSelect = false
            workspace.newBlankTab()
            let pane = workspace.selectedTab!.activePane, view = pane.terminal, terminal = view.getTerminal()
            var timestamp = ProcessInfo.processInfo.systemUptime
            func event(_ type: NSEvent.EventType, col: CGFloat, row: CGFloat = 0.5, shift: Bool = false, count: Int = 1) {
                // Overlay scrollers reserve no columns; optimal size gives the
                // real cell metrics rather than dividing a fractional viewport.
                let size = view.getOptimalFrameSize().size
                let width = size.width / CGFloat(terminal.cols), height = size.height / CGFloat(terminal.rows)
                let point = view.convert(NSPoint(x: col * width, y: view.bounds.height - row * height), to: nil)
                timestamp += 0.1
                let mouse = NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [], timestamp: timestamp,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
                switch type {
                case .leftMouseDown: view.mouseDown(with: mouse)
                case .leftMouseDragged: view.mouseDragged(with: mouse)
                default: view.mouseUp(with: mouse)
                }
            }
            func feed(_ text: String) { view.feed(text: "\u{1b}c" + text); view.selection.selectNone() }
            func selected() -> String { view.selection.getSelectedText() }
            view.scrollerStyle = .overlay
            for size in [CGFloat(13), CGFloat(19)] {
                view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                window.contentView?.layoutSubtreeIfNeeded()
                let prefix = "font\(Int(size))-"
                feed("abcdef")
                event(.leftMouseDown, col: 0.1)
                checks[prefix + "pressDoesNotSelect"] = !view.selection.active
                event(.leftMouseDragged, col: 4.8)
                checks[prefix + "coalescedFirstDragKeepsPressAnchor"] = selected() == "abcde"
                event(.leftMouseUp, col: 5.8)
                checks[prefix + "releaseIncludesFinalCharacter"] = selected() == "abcdef"
                feed("abcdef")
                event(.leftMouseDown, col: 0.1); event(.leftMouseDragged, col: 5.8)
                checks[prefix + "heldDragIncludesFinalCharacter"] = selected() == "abcdef"
                event(.leftMouseDragged, col: 5.2)
                checks[prefix + "leftHalfSnapsBeforeCharacter"] = selected() == "abcde"
                event(.leftMouseUp, col: 5.2)
                feed("abcdef")
                event(.leftMouseDown, col: 5.8); event(.leftMouseDragged, col: 2.2); event(.leftMouseUp, col: 0.1)
                checks[prefix + "backwardDragPreservesBothEnds"] = selected() == "abcdef"
                feed("abcdef")
                event(.leftMouseDown, col: 2.8); event(.leftMouseDragged, col: 5.8); event(.leftMouseDragged, col: 0.1); event(.leftMouseUp, col: 0.1)
                checks[prefix + "reverseAcrossAnchor"] = selected() == "abc"
                feed("abcdef")
                event(.leftMouseDown, col: 0.1); event(.leftMouseDragged, col: 0.8); event(.leftMouseUp, col: 0.8)
                checks[prefix + "oneCharacterDrag"] = selected() == "a"
                event(.leftMouseDown, col: 5.8, shift: true); event(.leftMouseUp, col: 5.8, shift: true)
                checks[prefix + "shiftExtendsThroughFinalCharacter"] = selected() == "abcdef"
                feed("abcdef")
                event(.leftMouseDown, col: 2.2); event(.leftMouseUp, col: 2.2)
                checks[prefix + "plainClickDoesNotCreateRange"] = !view.selection.active
                let fullLine = String(repeating: "x", count: terminal.cols - 1) + "Z"
                feed(fullLine)
                event(.leftMouseDown, col: 0.1); event(.leftMouseDragged, col: CGFloat(terminal.cols) - 0.2); event(.leftMouseUp, col: CGFloat(terminal.cols) + 0.5)
                checks[prefix + "rightmostColumnIncluded"] = selected() == fullLine && view.selection.end.col == terminal.cols
                feed("中文测试")
                event(.leftMouseDown, col: 0.1); event(.leftMouseDragged, col: 7.5); event(.leftMouseUp, col: 7.5)
                checks[prefix + "wideFinalCharacterIncluded"] = selected() == "中文测试" && view.selection.end.col == 8
                event(.leftMouseDown, col: 7.6); event(.leftMouseDragged, col: 0.1); event(.leftMouseUp, col: 0.1)
                checks[prefix + "wideBackwardDrag"] = selected() == "中文测试"
                feed("Ae\u{301}中🙂Z")
                event(.leftMouseDown, col: 0.1); event(.leftMouseDragged, col: 6.8); event(.leftMouseUp, col: 6.8)
                checks[prefix + "combiningAndEmojiRemainWhole"] = selected() == "Ae\u{301}中🙂Z"
                feed("abc\r\ndef")
                event(.leftMouseDown, col: 0.1); event(.leftMouseDragged, col: 2.8, row: 1.5); event(.leftMouseUp, col: 2.8, row: 1.5)
                checks[prefix + "multiLineFinalCharacterIncluded"] = selected() == "abc\ndef"
                feed("abc def")
                event(.leftMouseDown, col: 1.2, count: 2); event(.leftMouseUp, col: 1.2, count: 2)
                checks[prefix + "wordSelectionUnchanged"] = selected() == "abc"
                event(.leftMouseDragged, col: 5.8, count: 2); event(.leftMouseUp, col: 5.8, count: 2)
                checks[prefix + "wordDragUnchanged"] = selected() == "abc def"
                feed("abcdef\u{1b}[?1002h\u{1b}[?1006h")
                view.allowMouseReporting = true
                event(.leftMouseDown, col: 0.1); event(.leftMouseDragged, col: 5.8); event(.leftMouseUp, col: 5.8)
                checks[prefix + "remoteMouseDoesNotSelectLocally"] = !view.selection.active
                feed("abcdef\u{1b}[?1002h\u{1b}[?1006h")
                event(.leftMouseDown, col: 0.1, shift: true); event(.leftMouseDragged, col: 5.8, shift: true); event(.leftMouseUp, col: 5.8, shift: true)
                checks[prefix + "shiftLocalSelectionIncludesLastCharacter"] = selected() == "abcdef"
                view.feed(text: "\u{1b}[?1002l\u{1b}[?1006l")
            }
            checks["clipboardUntouched"] = NSPasteboard.general.changeCount == clipboardGeneration
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            workspace.shutdown(); NSApp.terminate(nil)
        }
    }
}
