import Foundation

/// Where Eider keeps its own state. `EIDER_HOME` moves all of it, which is
/// how the tests and the end-to-end run stay out of the owner's real library.
public struct EiderPaths: Sendable {
    public static let homeOverrideVariable = "EIDER_HOME"

    public let home: URL

    public init(
        home: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let home {
            self.home = home
        } else if let override = environment[Self.homeOverrideVariable], !override.isEmpty {
            self.home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.home = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Eider", isDirectory: true)
        }
    }

    /// Registry of installed apps (Library module).
    public var libraryFile: URL { home.appendingPathComponent("library.json") }
    /// Added sources and their last fetched contents (Catalog module).
    public var sourcesFile: URL { home.appendingPathComponent("sources.json") }
    /// First-seen SHA-256 per download URL (Downloads module).
    public var hashesFile: URL { home.appendingPathComponent("hashes.json") }
    public var downloads: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    public var cache: URL { home.appendingPathComponent("Cache", isDirectory: true) }

    public func ensure() throws {
        for directory in [home, downloads, cache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
