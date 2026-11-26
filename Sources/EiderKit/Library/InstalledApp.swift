import Foundation

/// Where an app installed from a source came from: the source's address, the
/// id the source lists the entry under, which since 0.1.2 may differ from
/// the id the IPA installed under ("com.kdt.l!vecontainer" installs as
/// "com.kdt.livecontainer"), and the name it lists it under: a tweak source
/// lists many different apps under one id, so the id alone does not say which.
/// Data only: the strings are compared with a catalog, never turned into a
/// path or a signing input (CatalogIdentifier).
public struct InstallOrigin: Codable, Sendable, Hashable {
    public let sourceURL: URL
    public let entryID: String
    /// The entry's name as listed. nil for an app installed by 0.1.4 to 0.1.6
    /// (the key is simply absent), whose entry may have been one of several
    /// under `entryID` (`UpdateChecker` then matches the installed app's name).
    public let entryName: String?

    public init(sourceURL: URL, entryID: String, entryName: String? = nil) {
        self.sourceURL = sourceURL
        self.entryID = entryID
        self.entryName = entryName
    }
}

/// One app Eider installed, as the library remembers it.
public struct InstalledApp: Codable, Sendable, Equatable, Identifiable {
    public var id: String { bundleID }

    public let bundleID: String
    public let name: String
    public let version: String
    public let build: String
    public let path: URL
    public let sourceURL: URL?
    /// Set by an install or update from a source; nil for a file or a plain
    /// address, and for entries written before 0.1.4 (the key is simply absent).
    public let origin: InstallOrigin?
    public let ipaSHA256: String?
    public let options: InstallOptions
    public let installedAt: Date
    public let engineVersion: String

    public init(
        bundleID: String, name: String, version: String, build: String, path: URL,
        sourceURL: URL? = nil, origin: InstallOrigin? = nil, ipaSHA256: String? = nil, options: InstallOptions,
        installedAt: Date = Date(), engineVersion: String = EiderVersion.current
    ) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.build = build
        self.path = path
        self.sourceURL = sourceURL
        self.origin = origin
        self.ipaSHA256 = ipaSHA256
        // Per-invocation choices are not part of what the app was installed as.
        self.options = options.withoutPerInvocationFlags
        self.installedAt = installedAt
        self.engineVersion = engineVersion
    }
}
