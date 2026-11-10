import Foundation

/// First SHA-256 seen per download URL (`EiderPaths.hashesFile`). A later
/// download of the same address that hashes differently is a changed file, which
/// for an unattended install is worth stopping on.
enum HashRecord {
    static func read(from file: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        do {
            let data = try Data(contentsOf: file)
            if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw DownloadFailure.hashRecordUnreadable(error.localizedDescription)
        }
    }

    static func write(_ records: [String: String], to file: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: file, options: .atomic)
        } catch {
            throw DownloadFailure.disk(error.localizedDescription)
        }
    }
}
