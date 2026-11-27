import EiderCore
import Foundation

/// The iOS app's own files, beside the ones EiderCore keeps in the same home
/// (Application Support/Eider): sources.json, hashes.json, Downloads, Cache.
extension EiderPaths {
    var ipas: URL { home.appendingPathComponent("IPAs", isDirectory: true) }
    var ipaIndexFile: URL { home.appendingPathComponent("ipas.json") }
    /// Apps Eider signed and installed on this device. Not `libraryFile`: that
    /// is the Mac library's format, whose records carry Mac engine options.
    var installedFile: URL { home.appendingPathComponent("installed.json") }
    var certificates: URL { home.appendingPathComponent("Certificates", isDirectory: true) }
    var certificateIndexFile: URL { certificates.appendingPathComponent("index.json") }
    /// Scratch space for one install at a time; emptied after each.
    var work: URL { home.appendingPathComponent("Work", isDirectory: true) }

    func ensureMobile() throws {
        try ensure()
        for directory in [ipas, certificates, work] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

/// Small JSON files written whole and atomically, so a crash mid-write leaves
/// the previous copy rather than half a file.
enum JSONFile {
    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
