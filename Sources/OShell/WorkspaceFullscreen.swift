// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

struct FullscreenWindowState {
    let titleVisibility: NSWindow.TitleVisibility
    let fullSizeContent: Bool
    let buttons: [(NSWindow.ButtonType, Bool)]
}

extension WorkspaceController {
    /// Prepare the native window before AppKit builds its fullscreen transition.
    /// Both entry points share this policy; focus mode only changes app chrome.
    func prepareFullscreenWindow() {
        guard let window else { return }
        if fullscreenWindowState == nil {
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            fullscreenWindowState = .init(titleVisibility: window.titleVisibility,
                fullSizeContent: window.styleMask.contains(.fullSizeContentView),
                buttons: types.map { ($0, window.standardWindowButton($0)?.isHidden ?? false) })
        }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        updateFullscreenButtons()
    }
    private func updateFullscreenButtons() {
        guard let window, let state = fullscreenWindowState else { return }
        // Ordinary fullscreen retains the system buttons when its titlebar is
        // revealed, so users can still leave fullscreen with the green button.
        for (type, hidden) in state.buttons {
            let targetHidden = isFocusFullscreen || hidden
            if let button = window.standardWindowButton(type), button.isHidden != targetHidden { button.isHidden = targetHidden }
        }
    }
    private func restoreWindowedPresentation() {
        guard let window, !window.styleMask.contains(.fullScreen), !isFocusFullscreen,
              let state = fullscreenWindowState else { return }
        window.titleVisibility = state.titleVisibility
        if state.fullSizeContent { window.styleMask.insert(.fullSizeContentView) }
        else { window.styleMask.remove(.fullSizeContentView) }
        for (type, hidden) in state.buttons { window.standardWindowButton(type)?.isHidden = hidden }
        fullscreenWindowState = nil
    }
    // Native-only window action; never add an unsupported action to the shared schema.
    static let deepFocusShortcut = KeyboardShortcut(3, KeyboardShortcut.command | KeyboardShortcut.control | KeyboardShortcut.shift)
    @objc func toggleDeepFocus() {
        guard isSecurityUnlocked, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        isDeepFocus.toggle()
        if isDeepFocus { requestFocusFullscreen(true) }
        refreshFocusContentChrome()
        selectedTab?.activePane.activate()
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    private func refreshFocusContentChrome() {
        for tab in tabs {
            let panes = tab.layout.panes
            panes.forEach { $0.setHeaderHidden(isDeepFocus || panes.count < 2) }
        }
        quickSendBar.isHidden = isDeepFocus || !configuration.preferences.quickSendBarVisible
        quickSendHeight?.constant = quickSendBar.isHidden ? 0 : 36
    }

    @objc func toggleFocusFullscreen() { requestFocusFullscreen(!focusFullscreenRequested) }
    func requestFocusFullscreen(_ enabled: Bool) {
        guard isSecurityUnlocked, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        focusFullscreenRequested = enabled
        reconcileFocusFullscreen()
    }
    private func reconcileFocusFullscreen() {
        guard let window else { return }
        if focusFullscreenRequested && !isFocusFullscreen { setFocusFullscreenChrome(true) }
        guard !fullscreenTransitionInProgress else { return }
        let native = window.styleMask.contains(.fullScreen)
        if focusFullscreenRequested && !native || !focusFullscreenRequested && isFocusFullscreen && native {
            fullscreenTransitionInProgress = true
            window.toggleFullScreen(nil)
        } else if !focusFullscreenRequested && isFocusFullscreen { setFocusFullscreenChrome(false) }
    }
    /// Only presentation changes: no session, tab, split or persistent preference is rebuilt.
    func setFocusFullscreenChrome(_ enabled: Bool) {
        guard enabled != isFocusFullscreen, let window else { return }
        isFocusFullscreen = enabled
        if enabled { prepareFullscreenWindow() }
        if !enabled { isDeepFocus = false }
        refreshFocusContentChrome()
        refreshSessionSidebar()
        normalWorkspaceTop?.isActive = !enabled; focusWorkspaceTop?.isActive = enabled
        topToolbar?.isHidden = enabled; topToolbar?.enclosingScrollView?.isHidden = enabled; topDivider?.isHidden = enabled
        sessionLinkBar.isHidden = enabled || !configuration.sessionLinks.visible
        refreshMasterWarning()
        updateFullscreenButtons()
        if !enabled { restoreWindowedPresentation() }
        window.contentView?.layoutSubtreeIfNeeded()
        refreshQuickSendBar()
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        fullscreenTransitionInProgress = true
        prepareFullscreenWindow()
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        fullscreenTransitionInProgress = false
        // AppKit still owns the animation transaction inside this callback.
        // Defer a queued toggle request until it can accept the opposite transition.
        if isFocusFullscreen { DispatchQueue.main.async { [weak self] in self?.reconcileFocusFullscreen() } }
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        fullscreenTransitionInProgress = true
        if isFocusFullscreen { focusFullscreenRequested = false }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenTransitionInProgress = false
        restoreWindowedPresentation()
        if isFocusFullscreen { DispatchQueue.main.async { [weak self] in self?.reconcileFocusFullscreen() } }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullscreenTransitionInProgress = false; focusFullscreenRequested = false; setFocusFullscreenChrome(false)
        restoreWindowedPresentation()
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullscreenTransitionInProgress = false
        if isFocusFullscreen { focusFullscreenRequested = true }
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        return proposedOptions.subtracting([.hideDock, .hideMenuBar]).union([.autoHideDock, .autoHideMenuBar, .autoHideToolbar])
    }
}
