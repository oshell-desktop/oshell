// SPDX-License-Identifier: GPL-3.0-only
import OShellCore

/// In-memory routing; opening the panel never decrypts legacy model settings on a key event.
enum AgentShortcut {
    static let binding: KeyboardShortcut? = KeyboardShortcut(0, KeyboardShortcut.control | KeyboardShortcut.option)
}
