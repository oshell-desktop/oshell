// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

// Separate disposable app so activation tests exercise the input-method handoff.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "OShell activation test peer"
let field = NSTextField(frame: NSRect(x: 20, y: 50, width: 360, height: 30))
window.contentView?.addSubview(field)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(field)
app.activate(ignoringOtherApps: true)
Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in app.terminate(nil) }
app.run()
