import CryptoKit
import Foundation

/// Fetched image bytes on disk, one file per URL, named by the URL's SHA-256.
/// The bound is kept by modification date: a read touches the file, so the
/// eviction drops what was least recently shown.
struct ImageDiskStore: Sendable {
    let directory: URL
    let limit: Int

    /// After going over the limit, trim down to this share of it, so the next
    /// few writes do not each trigger another scan.
    static let trimTarget = 0.8

    func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    func read(_ url: URL) -> Data? {
        let file = file(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    /// The number of bytes written, or nil when the write failed (a full disk
    /// costs a refetch later, nothing more).
    func write(_ data: Data, for url: URL) -> Int? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(for: url), options: .atomic)
            return data.count
        } catch {
            return nil
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: file(for: url))
    }

    /// Bytes stored now.
    func totalSize() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Deletes the least recently used files until the store is at
    /// `trimTarget` of `limit`, and returns the size left.
    @discardableResult
    func trim() -> Int {
        var entries = entries()
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return total }
        let target = Int(Double(limit) * Self.trimTarget)
        entries.sort { $0.date < $1.date }
        for entry in entries where total > target {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
        return total
    }

    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }
}
