// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

final class AIHistoryCloseTest {
    private static var retained: AIHistoryCloseTest?
    private let workspace: WorkspaceController
    private var checks = [String: Bool](), index = 0
    private weak var lastBrowser: AIHistoryBrowser?
    private var original: AIAssistantSession?, paneIDs = [UUID]()
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = AIHistoryCloseTest(workspace); retained = test
        do {
            struct Archive: Encodable { let version = 2; let entries: [AIHistory.Entry] }
            let rows = (0..<30).map { n in AIHistory.Entry(id: UUID(), date: Date(), target: .init(paneID: UUID(), stamp: "fixture", title: "历史测试 \(n)", metadata: ""), messages: [.init(role: "user", text: "第 \(n) 条历史问题"), .init(role: "assistant", text: String(repeating: "合成回答，仅用于取消测试。\n", count: 100))]) }
            try AIStorage.write(Archive(entries: rows), name: "history.json")
            workspace.newBlankTab(); workspace.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let assistant = workspace.getAIAssistant(); assistant.show()
            test.original = assistant.session; test.paneIDs = workspace.inputPanes.map(\.id)
            test.next()
        } catch { test.checks["setup"] = false; test.finish() }
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func next() {
        guard index < 24 else { finish(); return }
        let current = index; index += 1
        let timer = Timer(timeInterval: 0.08, repeats: false) { [self] _ in
            guard let window = NSApp.modalWindow, let root = window.contentView,
                  let browser = views(root).compactMap({ $0 as? AIHistoryBrowser }).first else { checks["visible-\(current)"] = false; NSApp.abortModal(); return }
            lastBrowser = browser
            let search = views(browser).compactMap { $0 as? NSSearchField }.first!
            window.makeFirstResponder(search); search.stringValue = current % 2 == 0 ? "历史" : "no-match-fixture"
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            if current % 3 == 0, let text = views(browser).compactMap({ $0 as? NSTextView }).first { window.makeFirstResponder(text); text.selectAll(nil) }
            if current < 16 { views(root).compactMap { $0 as? NSButton }.first { $0.title == "取消" }?.performClick(nil) }
            else if current < 20 { checks["escapeRouted-\(current)"] = PopupKeyboard.dismiss(window: window) }
            else {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
                checks["commandWRouted-\(current)"] = PopupKeyboard.closeAuxiliaryWindow(with: event, in: window)
            }
        }; RunLoop.main.add(timer, forMode: .modalPanel)
        autoreleasepool {
            views(workspace.getAIAssistant()).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.history" }?.performClick(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [self] in
            checks["historyBrowserReleased-\(current)"] = lastBrowser == nil
            checks["cancelPreservesApplication-\(current)"] = NSApp.modalWindow == nil && workspace.window?.isVisible == true && workspace.inputPanes.map(\.id) == paneIDs && workspace.getAIAssistant().session === original
            next()
        }
    }
    private func finish() {
        if let path = ProcessInfo.processInfo.environment["OSHELL_AI_HISTORY_CLOSE_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}
