// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Compiled only by the explicit developer build; never shipped in releases.
enum AppTestHarness {
// Explicit, isolated transfer harnesses can exercise offscreen AppKit views
// without taking keyboard focus from the user's foreground application.
    static let background = ProcessInfo.processInfo.environment["OSHELL_BACKGROUND_TEST"] == "1"
    && ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] != nil
    && CommandLine.arguments.contains(where: { ["--agent-control-test", "--auth-concurrency-test", "--login-password-save-test", "--third-party-import-test", "--keyboard-shortcuts-test", "--toolbar-actions-test", "--quicksend-groups-test", "--tab-behavior-test", "--layout-test", "--zmodem-progress-test", "--zmodem-regression-test", "--file-feature-test", "--search-test", "--host-identity-test", "--session-links-test", "--session-defaults-test", "--shell-integration-test", "--live-keepalive-test", "--appearance-test", "--quicksend-persistence-test", "--local-password-test", "--management-test", "--startup-protection-test", "--tab-drag-test", "--tab-actions-test", "--master-removal-test", "--update-feature-test", "--update-integration-test", "--terminal-focus-test", "--terminal-symbols-test", "--session-directory-test", "--quicksend-focus-test", "--arrangement-scroll-test", "--tab-number-test", "--links-catalog-test", "--named-tab-groups-test"].contains($0) })

    static func prepare() {
        // Test fonts are imported from development fixtures into isolated data;
        // neither the production app nor the test app bundles font binaries.
        if !CommandLine.arguments.contains("--font-library-test"), let root = ProcessInfo.processInfo.environment["OSHELL_TEST_FONT_ROOT"], ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] != nil {
            let fonts = ["NerdFonts", "DejaVuFonts", "CascadiaCode"].flatMap { directory in
                (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root).appendingPathComponent(directory), includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "ttf" } ?? []
            }
            do { try UserTerminalFonts.importFiles(fonts); UserTerminalFonts.register() } catch { NSLog("Synthetic fonts: %@", error.localizedDescription) }
        }
        if CommandLine.arguments.contains("--terminal-interrupt-test") { TerminalInterruptTest.prepare() }
        if CommandLine.arguments.contains("--encrypted-startup-test") { EncryptedStartupTest.install() }
    }
    static func run(_ controller: WorkspaceController) {
        if CommandLine.arguments.contains("--font-library-test") { FontLibraryTest.run(controller); return }
        if CommandLine.arguments.contains("--interface-design-test") { InterfaceDesignTest.run(controller); return }
        if CommandLine.arguments.contains("--file-presentation-test") { FilePresentationTest.run(controller); return }
        if CommandLine.arguments.contains("--agent-panel-test") { AgentPanelTest.run(controller); return }
        if CommandLine.arguments.contains("--agent-resources-test") { AgentResourceTest.run(controller); return }
        if CommandLine.arguments.contains("--agent-replay-test") { AgentReplayTest.run(controller); return }
        if CommandLine.arguments.contains("--agent-control-test") { AgentControlTest.run(controller); return }
        if CommandLine.arguments.contains("--wheel-gestures-test") { WheelGesturesTest.run(controller); return }
        GlobalProxyTest.configureNetworkFixture(controller)
        if CommandLine.arguments.contains("--finder-service-test") { FinderDirectoryServiceTest.run(controller); return }
        if CommandLine.arguments.contains("--activation-latency-test") { ActivationLatencyTest.run(controller); return }
        if CommandLine.arguments.contains("--fullscreen-activation-test") { FullscreenActivationTest.run(controller); return }
        if CommandLine.arguments.contains("--tiled-input-test") { TiledInputFocusTest.run(controller); return }
        if CommandLine.arguments.contains("--terminal-interrupt-test") { TerminalInterruptTest.run(controller); return }
        // Older UI fixtures explicitly exercise host-derived titles. Seed their
        // isolated local preference; the title-settings fixture tests the new default.
        if !CommandLine.arguments.contains("--tab-title-settings-test"), ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] != nil {
            var titles = (try? SessionTitleSettings.load()) ?? .init(); titles.defaultMode = .shellIntegration; try? titles.save()
        }
        if CommandLine.arguments.contains("--tab-close-confirmation-test") { TabCloseConfirmationTest.run(controller) }
        if CommandLine.arguments.contains("--session-catalog-presentation-test") { SessionCatalogPresentationTest.run(controller) }
        if CommandLine.arguments.contains("--marked-text-test") { MarkedTextOverlayTest.run(controller) }
        if CommandLine.arguments.contains("--tab-session-info-test") { TabSessionInfoTest.run(controller) }
        if CommandLine.arguments.contains("--image-paste-test") { ImagePasteTest.run(controller) }
        if CommandLine.arguments.contains("--session-pins-test") { SessionPinsTest.run(controller) }
        if CommandLine.arguments.contains("--tab-title-settings-test") { SessionTitleSettingsTest.run(controller) }

        if CommandLine.arguments.contains("--resource-review-test") { ResourceReviewTest.run(controller) }
        if CommandLine.arguments.contains("--tab-window-merge-test") { TabWindowMergeTest.run(controller) }
        if CommandLine.arguments.contains("--tab-detach-test") { TabDetachTest.run(controller) }
        if CommandLine.arguments.contains("--sync-settings-test") { SyncSettingsTest.run(controller) }
        if CommandLine.arguments.contains("--webdav-certificate-test") { WebDAVCertificateTest.run(controller) }
        if CommandLine.arguments.contains("--update-startup-state-test") { UpdateStartupStateTest.run(controller) }
        if CommandLine.arguments.contains("--file-resume-test") { FileResumeUITest.run(controller) }
        if CommandLine.arguments.contains("--file-transfer-history-test") { FileTransferHistoryTest.run(controller) }
        if CommandLine.arguments.contains("--session-sidebar-test") { SessionSidebarTest.run(controller) }
        if CommandLine.arguments.contains("--terminal-selection-test") { TerminalSelectionTest.run(controller) }
        if CommandLine.arguments.contains("--local-prompt-editing-test") { LocalPromptEditingTest.run(controller) }
        if CommandLine.arguments.contains("--biometric-local-store-test") { BiometricLocalStoreTest.run(controller) }
        if CommandLine.arguments.contains("--session-clipboard-test") { SessionClipboardTest.run(controller) }
        if CommandLine.arguments.contains("--file-window-keyboard-test") { FileWindowKeyboardTest.run(controller) }
        if CommandLine.arguments.contains("--readme-settings-test") { ReadmeScreenshots.runSettings(controller) }
        if CommandLine.arguments.contains("--readme-screenshots-test") { ReadmeScreenshots.run(controller) }
        if CommandLine.arguments.contains("--session-inline-rename-test") { SessionInlineRenameTest.run(controller) }
        if CommandLine.arguments.contains("--file-rate-test") { FileTransferRateTest.run(controller) }
        if CommandLine.arguments.contains("--tab-reorder-test") { TabReorderTest.run(controller) }
        if CommandLine.arguments.contains("--session-password-test") { SessionPasswordEditingTest.run(controller) }
        if CommandLine.arguments.contains("--zmodem-cancel-test") { ZmodemCancelTest.run(controller) }
        if CommandLine.arguments.contains("--file-metadata-test") { RemoteFileMetadataTest.run(controller) }
        if CommandLine.arguments.contains("--file-icons-test") { RemoteFileIconsTest.run(controller) }
        if CommandLine.arguments.contains("--external-launch-service"), ProcessInfo.processInfo.environment["OSHELL_SFTP_REUSE_TEST_ROOT"] != nil { SFTPReuseTest.run(controller) }
        if CommandLine.arguments.contains("--external-launch-service"), ProcessInfo.processInfo.environment["OSHELL_ZOC_CLONE_TEST_ROOT"] != nil { SSHCloneTest.run(controller) }
        if CommandLine.arguments.contains("--external-launch-service"), ProcessInfo.processInfo.environment["OSHELL_ZOC_TEST_ROOT"] != nil { ZOCLaunchTest.run(controller) }
        if CommandLine.arguments.contains("--external-launch-service"), ProcessInfo.processInfo.environment["OSHELL_FILE_LAUNCH_TEST_ROOT"] != nil { FileLaunchTest.run(controller) }
        if CommandLine.arguments.contains("--encrypted-startup-test") { EncryptedStartupTest.complete(controller) }
        if CommandLine.arguments.contains("--command-input-test") { CommandInputTest.run(controller) }
        if CommandLine.arguments.contains("--paste-scroll-test") { PasteScrollTest.run(controller) }
        if CommandLine.arguments.contains("--password-selection-test") { PasswordSelectionTest.run(controller) }
        if CommandLine.arguments.contains("--automatic-biometric-test") { AutomaticBiometricPromptTest.run(controller) }
        if CommandLine.arguments.contains("--biometric-unlock-test") { BiometricUnlockTest.run(controller) }
        if CommandLine.arguments.contains("--terminal-scroller-test") { TerminalScrollerTest.run(controller) }
        if CommandLine.arguments.contains("--theme-audit-test") { ThemeAuditTest.run(controller) }
        if CommandLine.arguments.contains("--terminal-chrome-test") { TerminalChromePreview.run(controller) }
        if CommandLine.arguments.contains("--focus-fullscreen-test") { FocusFullscreenTest.run(controller) }
        if CommandLine.arguments.contains("--unicode-display-test") { UnicodeDisplayTest.run(controller) }
        if CommandLine.arguments.contains("--tunnel-ownership-test") { TunnelOwnershipTest.run(controller) }
        if CommandLine.arguments.contains("--terminal-clock-test") { TerminalClockTest.run(controller) }
        if CommandLine.arguments.contains("--navigation-experience-test") { NavigationExperienceTest.run(controller) }
        if CommandLine.arguments.contains("--pane-close-test") { PaneCloseTest.run(controller) }
        if CommandLine.arguments.contains("--global-proxy-test") { GlobalProxyTest.run(controller) }
        if CommandLine.arguments.contains("--proxy-catalog-test") { ProxyCatalogTest.run(controller) }
        if CommandLine.arguments.contains("--directory-sync-test") { DirectorySyncTest.run(controller) }
        if CommandLine.arguments.contains("--webdav-test") { WebDAVFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--shared-conflict-test") { SharedConflictTest.run(controller) }
        if CommandLine.arguments.contains("--storage-sync-test") { StorageSyncTest.run(controller) }
        if CommandLine.arguments.contains("--multi-window-test") { MultiWindowTest.run(controller) }
        if CommandLine.arguments.contains("--named-tab-groups-test") { NamedTabGroupsTest.run(controller) }
        if CommandLine.arguments.contains("--links-catalog-test") { LinksCatalogTest.run(controller) }
        if CommandLine.arguments.contains("--tab-number-test") { TabNumberTest.run(controller) }
        if CommandLine.arguments.contains("--arrangement-scroll-test") { ArrangementScrollTest.run(controller) }
        if CommandLine.arguments.contains("--auth-concurrency-test") { AuthConcurrencyTest.run(controller) }
        if CommandLine.arguments.contains("--login-password-save-test") { LoginPasswordSavingTest.run(controller) }
        if CommandLine.arguments.contains("--third-party-import-test") { ThirdPartyImportTest.run(controller) }
        if CommandLine.arguments.contains("--keyboard-shortcuts-test") { KeyboardShortcutsTest.run(controller) }
        if CommandLine.arguments.contains("--toolbar-actions-test") { ToolbarActionsTest.run(controller) }
        if CommandLine.arguments.contains("--quicksend-groups-test") { QuickSendGroupsTest.run(controller) }
        if CommandLine.arguments.contains("--quicksend-focus-test") { QuickSendFocusTest.run(controller) }
        if CommandLine.arguments.contains("--session-directory-test") { SessionDirectoryTest.run(controller) }
        if CommandLine.arguments.contains("--directory-picker-stress-test") { DirectoryPickerStressTest.run(controller) }
        if CommandLine.arguments.contains("--terminal-symbols-test") { TerminalSymbolsTest.run(controller) }
        if CommandLine.arguments.contains("--terminal-focus-test") { TerminalFocusTest.run(controller) }
        if CommandLine.arguments.contains("--update-feature-test") { UpdateFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--update-integration-test") { UpdateIntegrationTest.run(controller) }
        if CommandLine.arguments.contains("--master-removal-test") { MasterRemovalTest.run(controller) }
        if CommandLine.arguments.contains("--tab-actions-test") { TabActionsTest.run(controller) }
        if CommandLine.arguments.contains("--tab-drag-test") { TabDragTest.run(controller) }
        if CommandLine.arguments.contains("--startup-protection-test") { StartupProtectionTest.run(controller) }
        if CommandLine.arguments.contains("--local-password-test") { LocalPasswordFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--quicksend-persistence-test") { QuickSendPersistenceTest.run(controller) }
        if CommandLine.arguments.contains("--appearance-test") { AppearanceFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--live-keepalive-test") { LiveKeepAliveTest.run(controller) }
        if CommandLine.arguments.contains("--shell-integration-test") { ShellIntegrationTest.run(controller) }
        if CommandLine.arguments.contains("--session-defaults-test") { SessionDefaultsTest.run(controller) }
        if CommandLine.arguments.contains("--session-links-test") { SessionLinksTest.run(controller) }
        if CommandLine.arguments.contains("--search-test") { SearchFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--smoke-test") { SmokeTest.run(controller) }
        if CommandLine.arguments.contains("--integration-test") { IntegrationTest.run(controller) }
        if CommandLine.arguments.contains("--stress-test") { StressTest.run(controller) }
        if CommandLine.arguments.contains("--session-test") { SessionFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--zmodem-progress-test") { ZmodemProgressUITest.run(controller) }
        if CommandLine.arguments.contains("--zmodem-regression-test") { ZmodemRegressionTest.run(controller) }
        if CommandLine.arguments.contains("--ended-session-test") { EndedSessionTest.run(controller) }
        if CommandLine.arguments.contains("--idle-tab-reuse-test") { IdleTabReuseTest.run(controller) }
        if CommandLine.arguments.contains("--tab-bar-menu-test") { TabBarMenuTest.run(controller) }
        if CommandLine.arguments.contains("--file-feature-test") { FileFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--operator-input-test") { OperatorInputTest.run(controller) }
        if CommandLine.arguments.contains("--operator-ui-test") { OperatorUITest.run(controller) }
        if CommandLine.arguments.contains("--session-fullscreen-test") { SessionFullscreenTest.run(controller) }
        if CommandLine.arguments.contains("--popup-keyboard-test") { PopupKeyboardTest.run(controller) }
        if CommandLine.arguments.contains("--memory-profile") { MemoryProfile.run(controller) }
        if CommandLine.arguments.contains("--memory-editor") { SessionMemoryProfile.run(controller) }
        if CommandLine.arguments.contains("--memory-cycles") { MemoryCycleProfile.run(controller) }
        if CommandLine.arguments.contains("--idle-memory-test") { IdleMemoryTest.run(controller) }
        if CommandLine.arguments.contains("--tab-behavior-test") { TabBehaviorTest.run(controller) }
        if CommandLine.arguments.contains("--host-identity-test") { HostIdentityTest.run(controller) }
        if CommandLine.arguments.contains("--session-list-test") { SessionListUITest.run(controller) }
        if CommandLine.arguments.contains("--management-test") { ManagementUITest.run(controller) }
        if CommandLine.arguments.contains("--quicksend-test") { QuickSendTest.run(controller) }
        if CommandLine.arguments.contains("--filetabs-test") { FileTabsTest.run(controller) }
        if CommandLine.arguments.contains("--unread-output-test") { UnreadOutputTest.run(controller) }
        if CommandLine.arguments.contains("--ended-broadcast-test") { EndedBroadcastTest.run(controller) }
        if CommandLine.arguments.contains("--local-tool-test") { LocalToolTest.run(controller) }
        if CommandLine.arguments.contains("--command-connection-test") { LocalToolTest.run(controller) }
        if CommandLine.arguments.contains("--filetabs-integration-test") { FileTabsIntegrationTest.run(controller) }
        if CommandLine.arguments.contains("--layout-test") { LayoutTest.run(controller) }
    }
}
