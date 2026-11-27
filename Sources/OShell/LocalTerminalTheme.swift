// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// The local terminal can read these display settings while the vault is locked.
struct LocalTerminalTheme: Codable, Equatable {
    let interface: InterfaceTheme
    let scheme: TerminalColorScheme
    // Older appearance snapshots contain only the interface and palette.
    let fontName: String?
    let fontSize: Double?

    init(_ preferences: Preferences) {
        interface = preferences.interfaceTheme
        scheme = preferences.colorScheme
        fontName = preferences.fontName
        fontSize = preferences.fontSize
    }

    static let changed = Notification.Name("app.oshell.localTerminalThemeChanged")
    static var domain: String {
        let host = Bundle.main.object(forInfoDictionaryKey: "OShellHostBundleIdentifier") as? String ?? Bundle.main.bundleIdentifier ?? "app.oshell.mac"
        return host + ".terminal-appearance"
    }
    private static let key = "activeTheme.v1" as CFString

    static func read() -> Self? {
        CFPreferencesAppSynchronize(domain as CFString)
        guard let data = CFPreferencesCopyAppValue(key, domain as CFString) as? Data,
              let theme = try? JSONDecoder().decode(Self.self, from: data),
              (try? theme.scheme.validate()) != nil else { return nil }
        return theme
    }

    private static var lastPublished: Self?
    static func publish(_ preferences: Preferences) {
        let theme = Self(preferences)
        guard theme != lastPublished else { return }
        if read() != theme {
            guard let data = try? JSONEncoder().encode(theme) else { return }
            CFPreferencesSetAppValue(key, data as CFData, domain as CFString)
            guard CFPreferencesAppSynchronize(domain as CFString) else { return }
            DistributedNotificationCenter.default().postNotificationName(changed, object: domain, userInfo: nil, deliverImmediately: true)
        }
        lastPublished = theme
    }

    func apply(to preferences: inout Preferences) {
        preferences.interfaceTheme = interface
        preferences.colorSchemeID = scheme.id
        preferences.customColorSchemes = TerminalColorScheme.presets.contains(where: { $0.id == scheme.id }) ? [] : [scheme]
        if let fontName { preferences.fontName = fontName }
        if let fontSize, (10...26).contains(fontSize) { preferences.fontSize = fontSize }
    }
}
