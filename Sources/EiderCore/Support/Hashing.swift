import CryptoKit
import Foundation

public enum Hashing {
    private static let chunkSize = 1 << 20

    /// Lower-case hex SHA-256 of a file, read in chunks so a multi-gigabyte
    /// IPA never sits in memory.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
