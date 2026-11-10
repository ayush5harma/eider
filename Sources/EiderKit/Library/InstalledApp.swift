import Foundation

/// One app Eider installed, as the library remembers it.
public struct InstalledApp: Codable, Sendable, Equatable, Identifiable {
    public var id: String { bundleID }

    public let bundleID: String
    public let name: String
    public let version: String
    public let build: String
    public let path: URL
    public let sourceURL: URL?
    public let ipaSHA256: String?
    public let options: InstallOptions
    public let installedAt: Date
    public let engineVersion: String

    public init(
        bundleID: String, name: String, version: String, build: String, path: URL,
        sourceURL: URL? = nil, ipaSHA256: String? = nil, options: InstallOptions,
        installedAt: Date = Date(), engineVersion: String = EiderVersion.current
    ) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.build = build
        self.path = path
        self.sourceURL = sourceURL
        self.ipaSHA256 = ipaSHA256
        self.options = options
        self.installedAt = installedAt
        self.engineVersion = engineVersion
    }
}
