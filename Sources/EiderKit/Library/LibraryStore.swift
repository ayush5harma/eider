import Foundation

/// The registry of installed apps, one JSON file under `EiderPaths.home`.
/// A missing or empty file is an empty library; a file that does not decode
/// is an error, never silently replaced (that would forget every app).
public actor LibraryStore {
    private let file: URL

    public init(paths: EiderPaths = EiderPaths()) {
        file = paths.libraryFile
    }

    public func all() throws -> [InstalledApp] {
        try load().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func app(bundleID: String) throws -> InstalledApp? {
        try load().first { $0.bundleID == bundleID }
    }

    /// Add the app, or replace the entry with the same bundle id.
    public func record(_ app: InstalledApp) throws {
        try save(load().filter { $0.bundleID != app.bundleID } + [app])
    }

    public func remove(bundleID: String) throws {
        try save(load().filter { $0.bundleID != bundleID })
    }

    // MARK: File

    private func load() throws -> [InstalledApp] {
        guard let data = try? Data(contentsOf: file), !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A }) else { return [] }
        // An entry whose id is not a valid bundle id was not written by Eider; it is
        // dropped on read, and the next save forgets it.
        return try Self.decoder.decode([InstalledApp].self, from: data).filter { BundleIdentifier.isValid($0.bundleID) }
    }

    private func save(_ apps: [InstalledApp]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(apps).write(to: file, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
