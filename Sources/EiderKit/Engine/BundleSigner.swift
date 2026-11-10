import Foundation

/// Ad hoc signing, strict verification and quarantine removal for an unpacked bundle.
struct BundleSigner {
    static let codesign = "/usr/bin/codesign"

    /// PlayCover's base set: sandboxed, so the app gets its own container instead
    /// of writing into ~/Documents, with the capabilities a sandboxed app may ASK
    /// for (camera, microphone, location, contacts, calendars, files).
    static let entitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>com.apple.security.app-sandbox</key><true/>
      <key>com.apple.security.network.client</key><true/>
      <key>com.apple.security.network.server</key><true/>
      <key>com.apple.security.device.camera</key><true/>
      <key>com.apple.security.device.audio-input</key><true/>
      <key>com.apple.security.device.bluetooth</key><true/>
      <key>com.apple.security.device.usb</key><true/>
      <key>com.apple.security.files.downloads.read-write</key><true/>
      <key>com.apple.security.files.user-selected.read-write</key><true/>
      <key>com.apple.security.personal-information.addressbook</key><true/>
      <key>com.apple.security.personal-information.calendars</key><true/>
      <key>com.apple.security.personal-information.location</key><true/>
      <key>com.apple.security.assets.movies.read-write</key><true/>
      <key>com.apple.security.assets.music.read-write</key><true/>
      <key>com.apple.security.assets.pictures.read-write</key><true/>
      <key>com.apple.security.print</key><true/>
    </dict></plist>
    """

    let app: URL
    let workDirectory: URL
    let relative: (URL) -> String

    // MARK: Sign

    /// Every Mach-O on its own (`codesign --deep` finds no nested code in an iOS
    /// flat bundle, so frameworks would keep the signature of the bytes just
    /// rewritten and the kernel would kill the process at dyld's first page),
    /// then each nested bundle inside-out, then the app with its entitlements.
    /// Serial on purpose: signing the main binary and a framework binary of the
    /// same bundle at once failed with "No such file or directory" on the first
    /// end-to-end run (2026-11-11), so the legacy one-at-a-time order is kept.
    func sign(machOs: [URL]) throws {
        for file in machOs {
            let result = try ProcessRunner.run(Self.codesign, ["--force", "--sign", "-", file.path])
            guard result.succeeded else {
                throw InstallFailure(.signingFailed, "codesign failed on \(relative(file)): \(result.errorLine)")
            }
        }
        for bundle in nestedBundles() {
            _ = try? ProcessRunner.run(Self.codesign, ["--force", "--sign", "-", bundle.path])
        }
        let entitlementsFile = workDirectory.appendingPathComponent("entitlements.plist")
        try Self.entitlements.write(to: entitlementsFile, atomically: true, encoding: .utf8)
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
