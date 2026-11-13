// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

extension TerminalPane {
    func preserveScrollback(from old: TerminalPane) {
        guard old.profile.kind == .ssh else { return }
        terminal.getTerminal().takeScrollbackForReconnect(from: old.terminal.getTerminal())
        terminal.feed(text: "[OShell · 重新连接，已保留之前的终端输出]\r\n")
    }
}
