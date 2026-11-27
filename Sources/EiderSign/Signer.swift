import CZsign
import Foundation

/// Signs unpacked apps with the user's own certificate, using zsign.
public enum Signer {
    /// Signs the .app at `appURL` in place: frameworks, dylibs, extensions and
    /// watch apps inner first, then the app, with the profile's entitlements
    /// (application-identifier set to each bundle's own id) and the profile
    /// written as embedded.mobileprovision.
    ///
    /// Refuses before touching anything when the certificate or profile has
    /// expired, or when an explicit profile does not cover the final bundle
    /// identifier of the app or of one of its extensions.
    public static func sign(
        appAt appURL: URL,
        certificate: SigningCertificate,
        options: SigningOptions = SigningOptions()
    ) async throws {
        try await ZsignEngine.shared.sign(appAt: appURL, certificate: certificate, options: options, now: Date())
    }
}

/// zsign keeps process-wide state (log level, last error), so every signing
/// runs here, one at a time. The executor is a serial dispatch queue rather
/// than the cooperative pool because signing blocks on file I/O and hashing
/// for seconds at a time.
actor ZsignEngine {
    static let shared = ZsignEngine()

    private let queue = DispatchSerialQueue(label: "io.github.ayush5harma.eider.zsign", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func sign(appAt appURL: URL, certificate: SigningCertificate, options: SigningOptions, now: Date) throws {
        if certificate.certificateExpires <= now {
            throw SigningError.certificateExpired(certificate.certificateExpires)
        }
        if certificate.profileExpires <= now {
            throw SigningError.profileExpired(certificate.profileExpires)
        }
        if let newIdentifier = options.bundleIdentifier, !newIdentifier.isEmpty,
           !AppBundle.isValidBundleIdentifier(newIdentifier) {
            throw SigningError.invalidBundleIdentifier(newIdentifier)
        }
        let app = try AppBundle(url: appURL)
        for bundleIdentifier in app.finalBundleIdentifiers(renamingTo: options.bundleIdentifier)
        where !certificate.allows(bundleIdentifier: bundleIdentifier) {
            throw SigningError.bundleIdentifierNotAllowed(
                bundleIdentifier: bundleIdentifier,
                profileName: certificate.profileName,
                allowed: certificate.allowedBundleIdentifiers)
        }
        // zsign reads the p12 and profile from files. They go to a private
        // folder (0700) and are removed whatever happens.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("eider-sign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let p12URL = workspace.appendingPathComponent("identity.p12")
        let profileURL = workspace.appendingPathComponent("embedded.mobileprovision")
        try certificate.p12Data.write(to: p12URL, options: .atomic)
        try certificate.profileData.write(to: profileURL, options: .atomic)
        // Last change before zsign, so a failure above leaves the app as it was.
        if options.removeURLSchemes {
            try app.removeMainInfoKey("CFBundleURLTypes")
        }

        var errorPointer: UnsafeMutablePointer<CChar>?
        defer { eider_string_free(errorPointer) }
        let result = app.url.path.withCString { appPath in
            p12URL.path.withCString { p12Path in
                profileURL.path.withCString { profilePath in
                    certificate.password.withCString { password in
                        withOptionalCString(options.bundleIdentifier) { bundleID in
                            withOptionalCString(options.displayName) { displayName in
                                withOptionalCString(options.version) { version in
                                    var request = eider_sign_request(
                                        app_path: appPath,
                                        p12_path: p12Path,
                                        password: password,
                                        profile_path: profilePath,
                                        bundle_id: bundleID,
                                        display_name: displayName,
                                        version: version,
                                        enable_documents: options.enableFileSharing ? 1 : 0,
                                        remove_supported_devices: options.removeSupportedDevices ? 1 : 0)
                                    return eider_sign_app(&request, &errorPointer)
                                }
                            }
                        }
                    }
                }
            }
        }
        guard result == 0 else {
            throw SigningError.signingFailed(errorPointer.map { String(cString: $0) } ?? "zsign could not sign the app.")
        }
    }
}

private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let value, !value.isEmpty else { return body(nil) }
    return value.withCString { body($0) }
}

/// The .app being signed: its Info.plist and those of the apps and
/// extensions inside it.
struct AppBundle {
    let url: URL
    let bundleIdentifier: String
    /// Nested .app and .appex bundles (extensions, watch apps), any depth.
    let nestedBundleIdentifiers: [String]

    init(url: URL) throws {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let info = Self.info(at: url),
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty
        else {
            throw SigningError.notAnApp(path: url.lastPathComponent)
        }
        self.url = url
        bundleIdentifier = identifier
        var nested: [String] = []
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        while let item = enumerator?.nextObject() as? URL {
            guard ["app", "appex"].contains(item.pathExtension),
                  let identifier = Self.info(at: item)?["CFBundleIdentifier"] as? String
            else { continue }
            nested.append(identifier)
        }
        nestedBundleIdentifiers = nested
    }

    /// The identifiers after zsign renames the bundle: the app's becomes the
    /// new one and each nested one has the old app id replaced by the new.
    func finalBundleIdentifiers(renamingTo newIdentifier: String?) -> [String] {
        guard let newIdentifier, !newIdentifier.isEmpty else {
            return [bundleIdentifier] + nestedBundleIdentifiers
        }
        return [newIdentifier] + nestedBundleIdentifiers.map {
            $0.replacingOccurrences(of: bundleIdentifier, with: newIdentifier)
        }
    }

    /// Letters, digits, hyphens and dots, with no empty component: what iOS
    /// accepts in CFBundleIdentifier.
    static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        return !components.contains { $0.isEmpty || !$0.allSatisfy(allowed.contains) }
    }

    func removeMainInfoKey(_ key: String) throws {
        let infoURL = url.appendingPathComponent("Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.xml
        let data = try Data(contentsOf: infoURL)
        guard var info = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
            throw SigningError.notAnApp(path: url.lastPathComponent)
        }
        guard info.removeValue(forKey: key) != nil else { return }
        let updated = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
        try updated.write(to: infoURL, options: .atomic)
    }

    private static func info(at bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
