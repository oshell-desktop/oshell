// SPDX-License-Identifier: GPL-3.0-only
import OShellCore

/// Shortcut routing stays in memory; key events do not perform file I/O.
enum AgentShortcut {
    static let binding: KeyboardShortcut? = KeyboardShortcut(0, KeyboardShortcut.control | KeyboardShortcut.option)
}
