import Foundation

/// Ad hoc signing, strict verification and quarantine removal for an unpacked bundle.
struct BundleSigner {
    static let codesign = "/usr/bin/codesign"

    /// PlayCover's base set: sandboxed, so the app gets its own container instead
    /// of writing into ~/Documents, with the capabilities a sandboxed app may ASK
    /// for (camera, microphone, location, contacts, calendars, files).
    static let baseEntitlements: [String: Bool] = [
        "com.apple.security.app-sandbox": true,
        "com.apple.security.network.client": true,
        "com.apple.security.network.server": true,
        "com.apple.security.device.camera": true,
        "com.apple.security.device.audio-input": true,
        "com.apple.security.device.bluetooth": true,
        "com.apple.security.device.usb": true,
        "com.apple.security.files.downloads.read-write": true,
        "com.apple.security.files.user-selected.read-write": true,
        "com.apple.security.personal-information.addressbook": true,
        "com.apple.security.personal-information.calendars": true,
        "com.apple.security.personal-information.location": true,
        "com.apple.security.assets.movies.read-write": true,
        "com.apple.security.assets.music.read-write": true,
        "com.apple.security.assets.pictures.read-write": true,
        "com.apple.security.print": true,
    ]

    /// The app's entitlements as an XML plist: the base set, plus the app's own
    /// app-group ids when it has any. Built as a dictionary and serialised, never
    /// templated, so no id can break out of the plist. `appGroups` must already
    /// have passed `AppGroups.filter`.
    static func entitlementsPlist(appGroups: [String]) throws -> Data {
        var entitlements: [String: Any] = baseEntitlements
        if !appGroups.isEmpty { entitlements[AppGroups.entitlementKey] = appGroups }
        return try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    }

    let app: URL
    let workDirectory: URL
    let relative: (URL) -> String

    // MARK: Sign

    /// Every Mach-O on its own (`codesign --deep` finds no nested code in an iOS
    /// flat bundle, so frameworks would keep the signature of the bytes just
    /// rewritten and the kernel would kill the process at dyld's first page),
    /// then each nested bundle inside-out, then the app with its entitlements
    /// (the base set and `appGroups`; nested bundles are signed without any).
    /// Serial on purpose: signing the main binary and a framework binary of the
    /// same bundle at once failed with "No such file or directory" on the first
    /// end-to-end run (2026-11-11), so the legacy one-at-a-time order is kept.
    ///
    /// A nested bundle that will not sign is not an install failure by itself (an
    /// iOS bundle can carry resource bundles codesign has no use for), but it is
    /// reported through `warn` instead of vanishing; `verify` is the gate.
    func sign(machOs: [URL], appGroups: [String] = [], warn: (String) -> Void = { _ in }) throws {
        for file in machOs {
            let result = try ProcessRunner.run(Self.codesign, ["--force", "--sign", "-", file.path])
            guard result.succeeded else {
                throw InstallFailure(.signingFailed, "codesign failed on \(relative(file)): \(result.errorLine)")
            }
        }
        for bundle in nestedBundles() {
            do {
                let result = try ProcessRunner.run(Self.codesign, ["--force", "--sign", "-", bundle.path])
                if !result.succeeded { warn("Could not sign the nested bundle \(relative(bundle)): \(result.errorLine)") }
            } catch {
                warn("Could not sign the nested bundle \(relative(bundle)): \(error)")
            }
        }
        let entitlementsFile = workDirectory.appendingPathComponent("entitlements.plist")
        try Self.entitlementsPlist(appGroups: appGroups).write(to: entitlementsFile, options: .atomic)
        let result = try ProcessRunner.run(Self.codesign, ["--force", "--sign", "-", "--entitlements", entitlementsFile.path, app.path])
        guard result.succeeded else { throw InstallFailure(.signingFailed, "codesign failed on the app: \(result.errorLine)") }
    }

    /// Frameworks, extensions and bundles that carry an Info.plist (iOS or macOS layout), deepest first.
    func nestedBundles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var bundles: [URL] = []
        for case let url as URL in walker where ["framework", "appex", "bundle"].contains(url.pathExtension) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let hasPlist = ["Info.plist", "Contents/Info.plist"].contains {
                FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
            }
            if isDirectory, hasPlist { bundles.append(url) }
        }
        return bundles.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    // MARK: Verify

    /// Verify every Mach-O the way dyld will, not only the bundle seal.
    func verify(machOs: [URL]) throws {
        var unverified: [String] = []
        for file in machOs {
            let result = try ProcessRunner.run(Self.codesign, ["--verify", "--strict", file.path])
            if !result.succeeded { unverified.append(relative(file)) }
        }
        unverified.sort()
        guard unverified.isEmpty else {
            throw InstallFailure(.verificationFailed, "These binaries would be killed at load because their signature does not verify: \(unverified.joined(separator: ", ")).")
        }
        let result = try ProcessRunner.run(Self.codesign, ["--verify", "--strict", app.path])
        guard result.succeeded else {
            throw InstallFailure(.verificationFailed, "The app's signature does not verify: \(result.errorLine)")
        }
    }

    // MARK: Quarantine

    /// Clear com.apple.quarantine on everything, so Gatekeeper does not ask about an app the owner chose to install.
    static func clearQuarantine(under root: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(root.path, attribute, XATTR_NOFOLLOW)
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return }
        for case let path as String in walker {
            removexattr(root.appendingPathComponent(path).path, attribute, XATTR_NOFOLLOW)
        }
    }
}
