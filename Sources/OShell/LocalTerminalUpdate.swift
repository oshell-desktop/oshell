// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import OShellCore
import Security

/// Sparkle replaces the host. On the next launch, install the signed companion
/// carried by that exact host build, only for users who selected the option.
final class LocalTerminalUpdate: NSObject {
    static let shared = LocalTerminalUpdate()
    private static let key = "OShell.updates.localTerminal.lastBuild"
    private static let filename = OShellAppPair.terminalFilename
    private static var build: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) != nil }

    static func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if value { UserDefaults.standard.set(build, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(terminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        attempt()
    }

    @objc private func terminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Bundle.main.object(forInfoDictionaryKey: "OShellLocalTerminalBundleIdentifier") as? String else { return }
        DispatchQueue.main.async { self.attempt() }
    }

    private var installing = false
    private func attempt() {
        let defaults = UserDefaults.standard
        guard !installing, Self.enabled, Self.build > defaults.integer(forKey: Self.key),
              let identifier = Bundle.main.object(forInfoDictionaryKey: "OShellLocalTerminalBundleIdentifier") as? String else { return }
        installing = true
        defer { installing = false }
        do {
            let fm = FileManager.default
            let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(Self.filename)
            let userApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            let userCopy = userApps.appendingPathComponent(Self.filename)
            let destination: URL
            func hasInstalledCopy(_ url: URL) -> Bool {
                Self.exists(url) || Self.exists(url.deletingLastPathComponent().appendingPathComponent(OShellAppPair.previousTerminalFilename))
            }
            if hasInstalledCopy(sibling) || (!hasInstalledCopy(userCopy) && fm.isWritableFile(atPath: sibling.deletingLastPathComponent().path)) {
                destination = sibling
            } else {
                try fm.createDirectory(at: userApps, withIntermediateDirectories: true)
                destination = userCopy
            }
            let host = Bundle.main
            guard let archive = host.url(forResource: "LocalTerminal", withExtension: "zip"),
                  let digest = host.object(forInfoDictionaryKey: "OShellLocalTerminalArchiveSHA256") as? String,
                  let hostID = host.bundleIdentifier else { throw ModelError.invalid("此版本缺少本地终端安装资源。") }
            if try Self.install(archive: archive, digest: digest, destination: destination, identifier: identifier,
                                host: hostID, build: Self.build, running: {
                NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { !$0.isTerminated }
            }) { defaults.set(Self.build, forKey: Self.key) }
        } catch {
            Dialogs.message("本地终端尚未安装或更新：\(error.localizedDescription)\n下次打开 OShell 时会重试，也可从同版本 DMG 手动安装。")
        }
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func checkedCode(_ url: URL, requirement: SecRequirement? = nil) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw ModelError.invalid("本地终端的代码签名不匹配。")
        }
        return code
    }

    /// Returns false when a live terminal should be retried after it exits.
    static func install(archive: URL, digest: String, destination: URL, identifier: String, host: String,
                        build: Int, running: () -> Bool) throws -> Bool {
        if running() { return false }
        let fm = FileManager.default
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw ModelError.invalid("本地终端安装资源的校验值不匹配。")
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".oshell-terminal-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let verifiedArchive = stage.appendingPathComponent("verified.zip")
        try bytes.write(to: verifiedArchive, options: .withoutOverwriting)
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", verifiedArchive.path, stage.path]
        try extract.run(); extract.waitUntilExit()
        guard extract.terminationStatus == 0 else { throw ModelError.invalid("无法解压本地终端安装资源。") }
        let source = stage.appendingPathComponent(filename)
        func version(_ url: URL, legacyLauncher: Bool = false) throws -> Int {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true,
                  let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == identifier, info["OShellHostBundleIdentifier"] as? String == host,
                  legacyLauncher || info["OShellOwnsLocalWindows"] as? Bool == true,
                  let raw = info["CFBundleVersion"] as? String, let value = Int(raw) else {
                throw ModelError.invalid("应用身份不匹配：\(url.lastPathComponent)")
            }
            return value
        }
        guard try version(source) == build else { throw ModelError.invalid("本地终端与 OShell 的版本不匹配。") }
        let code = try checkedCode(source)
        let legacy = destination.deletingLastPathComponent().appendingPathComponent(OShellAppPair.previousTerminalFilename)
        let installed = exists(destination) ? destination : legacy
        let replacing = exists(installed)
        if replacing {
            let previous = try version(installed, legacyLauncher: installed == legacy)
            var requirement: SecRequirement?
            guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
                throw ModelError.invalid("无法验证已安装的本地终端。")
            }
            _ = try checkedCode(installed, requirement: requirement)
            if previous > build { return true }
            if previous == build && installed == destination,
               let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")),
               info["CFBundleName"] as? String == "oTerm" { return true }
        }
        if running() { return false }
        if replacing && installed == legacy {
            guard renameatx_np(AT_FDCWD, legacy.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        // A pinned Dock item can track the old directory by its file ID.
        // Keep that directory through the rename and swap its signed contents.
        let migrating = replacing && installed == legacy
        let incoming = migrating ? source.appendingPathComponent("Contents") : source
        let target = migrating ? destination.appendingPathComponent("Contents") : destination
        guard renameatx_np(AT_FDCWD, incoming.path, AT_FDCWD, target.path, UInt32(replacing ? RENAME_SWAP : RENAME_EXCL)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if replacing && installed == legacy {
                _ = renameatx_np(AT_FDCWD, destination.path, AT_FDCWD, legacy.path, UInt32(RENAME_EXCL))
            }
            throw error
        }
        NSWorkspace.shared.noteFileSystemChanged(destination.path)
        return true
    }
}
