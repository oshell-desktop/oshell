// SPDX-License-Identifier: GPL-3.0-only
import OShellCore

/// Hide obsolete factory shortcuts in native lists without deleting shared data.
enum SessionCatalogPresentation {
    private static let factoryProfile = SessionProfile.local
    static func visibleConfiguration(_ configuration: Configuration) -> Configuration {
        let referenced = Set(configuration.sessionLinks.entries.map(\.profileID))
        let hidden = configuration.profiles.filter { profile in
            guard profile.kind == .local, !referenced.contains(profile.id),
                  ["", "本机"].contains(profile.group) else { return false }
            var factory = factoryProfile
            factory.id = profile.id; factory.group = profile.group; factory.proxy.id = profile.proxy.id
            return profile == factory
        }
        guard !hidden.isEmpty else { return configuration }
        let ids = Set(hidden.map(\.id))
        var visible = configuration
        visible.profiles.removeAll { ids.contains($0.id) }
        if !visible.profiles.contains(where: { SessionDirectory.contains($0.group, in: "本机") }),
           !visible.directories.contains(where: { $0 != "本机" && SessionDirectory.contains($0, in: "本机") }) {
            visible.directories.removeAll { $0 == "本机" }
        }
        return visible
    }
}
