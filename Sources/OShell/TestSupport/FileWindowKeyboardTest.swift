// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum FileWindowKeyboardTest {
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { start(workspace) }
    }
    private static func start(_ workspace: WorkspaceController) {
        workspace.newBlankTab()
        let originalTabs = workspace.tabs.map(\.id)
        var checks = [String:Bool](), backends = [TabTestBackend](), finished = false
        let files = RemoteFileWindow(workspace:workspace) { profile in
            let backend = TabTestBackend(profile.name, timeout:30); backends.append(backend); return backend
        }
        files.showWindow(nil); NSApp.activate(ignoringOtherApps:true)
        files.open(SessionProfile(name:"one",kind:.sftp,host:"192.0.2.10"),directory:"/one")
        files.open(SessionProfile(name:"two",kind:.sftp,host:"192.0.2.11"),directory:"/two")
        let fileWindow = files.window!, sessions = files.sessions
        func finish() {
            guard !finished else { return }; finished = true
            files.close(); workspace.shutdown()
            let report:[String:Any] = ["passed":checks.values.allSatisfy { $0 },"checks":checks]
            if let path = ProcessInfo.processInfo.environment["OSHELL_FILE_WINDOW_KEYS_OUTPUT"] { try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path)) }
            NSApp.terminate(nil)
        }
        func wait(_ name:String,_ condition:@escaping()->Bool,_ action:@escaping()->Void) {
            let deadline = Date().addingTimeInterval(8)
            func poll() {
                guard !finished else { return }
                if condition() { checks[name] = true; action() }
                else if Date() > deadline { checks[name] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline:.now()+0.05) { poll() } }
            }
            poll()
        }
        func event(_ command:Bool)->NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:command ? .command : [],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:fileWindow.windowNumber,context:nil,characters:command ? "w" : "\u{1b}",charactersIgnoringModifiers:command ? "w" : "\u{1b}",isARepeat:false,keyCode:command ? 13 : 53)!
        }
        func modal(_ body:@escaping(NSWindow)->Void) {
            let timer = Timer(timeInterval:0.15,repeats:false) { _ in
                if let window = NSApp.modalWindow { body(window) }
                else { checks["expectedModal"] = false; NSApp.abortModal() }
            }
            RunLoop.main.add(timer,forMode:.common); RunLoop.main.add(timer,forMode:.modalPanel)
        }
        wait("bothConnected",{ sessions.allSatisfy(\.connected) && fileWindow.isKeyWindow && NSApp.isActive }) {
            checks["nativeMinimizeButtonEnabled"] = fileWindow.styleMask.contains(.miniaturizable)
            let menu = NSMenu()
            NotificationCenter.default.post(name:NSMenu.didBeginTrackingNotification,object:menu)
            checks["menuEscapeDoesNotMinimize"] = !PopupKeyboard.dismiss(window:fileWindow) && !fileWindow.isMiniaturized
            NotificationCenter.default.post(name:NSMenu.didEndTrackingNotification,object:menu)
            NSApp.postEvent(event(false),atStart:false)
            wait("escapeMinimizes",{ fileWindow.isMiniaturized }) {
                checks["minimizeKeepsAllConnections"] = files.sessions.map(\.id) == sessions.map(\.id) && sessions.allSatisfy(\.connected) && backends.allSatisfy { !$0.isCancelled }
                checks["escapeDoesNotCloseSSH"] = workspace.tabs.map(\.id) == originalTabs
                NSApp.activate(ignoringOtherApps: true); files.showWindow(nil)
                wait("restoresSameWindow",{ !fileWindow.isMiniaturized && fileWindow.isKeyWindow }) {
                    checks["restoresFileState"] = sessions.map(\.directory) == ["/one","/two"]
                    modal { _ in NSApp.stopModal(withCode:.alertFirstButtonReturn) }
                    sessions[0].upload([workspace.store.url.deletingLastPathComponent().appendingPathComponent("fixture.txt")],to:"/one")
                    wait("uploadStarted",{ backends[0].uploadStarted && files.hasActiveOperation }) {
                        NSApp.postEvent(event(false),atStart:false)
                        wait("escapeMinimizesDuringTransfer",{ fileWindow.isMiniaturized }) {
                            checks["transferSurvivesMinimize"] = files.hasActiveOperation && !backends[0].isCancelled
                            NSApp.activate(ignoringOtherApps: true); files.showWindow(nil)
                            wait("restoredDuringTransfer",{ fileWindow.isKeyWindow && !fileWindow.isMiniaturized }) {
                                var cancelledPrompt = false
                                modal { alert in
                                    cancelledPrompt = true
                                    checks["commandWIgnoredBehindModal"] = !PopupKeyboard.closeAuxiliaryWindow(with:event(true),in:fileWindow)
                                    _ = PopupKeyboard.dismiss(window:alert)
                                }
                                NSApp.postEvent(event(true),atStart:false)
                                wait("closeConfirmationCancelled",{ cancelledPrompt && NSApp.modalWindow == nil }) {
                                    checks["cancelCloseKeepsConnections"] = sessions.allSatisfy(\.connected) && backends.allSatisfy { !$0.isCancelled } && fileWindow.isVisible
                                    checks["cancelledCommandWDoesNotReachSSH"] = workspace.tabs.map(\.id) == originalTabs
                                    modal { _ in NSApp.stopModal(withCode:.alertFirstButtonReturn) }
                                    NSApp.postEvent(event(true),atStart:false)
                                    wait("commandWClosesFileWindow",{ files.sessions.isEmpty && sessions.allSatisfy(\.closed) }) {
                                        checks["confirmedCloseCancelsFileBackends"] = backends.allSatisfy(\.isCancelled)
                                        checks["commandWLeavesSSHWindowOpen"] = workspace.tabs.map(\.id) == originalTabs && workspace.window?.isVisible == true
                                        finish()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
