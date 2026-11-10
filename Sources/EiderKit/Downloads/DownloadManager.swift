import CryptoKit
import Foundation

/// Downloads IPAs into `EiderPaths.downloads`, safely: through a `.part` file,
/// under a size cap, over https, and checked against the checksum the source
/// published and against the first hash this address ever served.
public actor DownloadManager {
    public static let defaultMaxBytes: Int64 = 8 * 1024 * 1024 * 1024

    private let paths: EiderPaths
    private let maxBytes: Int64
    private let transfer: HTTPTransfer
    private var inFlight: Set<URL> = []

    public init(
        paths: EiderPaths = EiderPaths(),
        configuration: URLSessionConfiguration = .ephemeral,
        maxBytes: Int64 = DownloadManager.defaultMaxBytes
    ) {
        self.paths = paths
        self.maxBytes = maxBytes
        self.transfer = HTTPTransfer(configuration: configuration)
    }

    deinit {
        transfer.invalidate()
    }

    /// Cancelling the consuming task cancels the transfer and keeps the `.part`.
    public nonisolated func download(
        _ version: CatalogVersion, of app: CatalogApp, allowChangedHash: Bool = false
    ) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(version, of: app, allowChangedHash: allowChangedHash) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    if let failure = DownloadFailure.wrap(error) {
                        continuation.finish(throwing: failure)
                    } else {
                        continuation.finish()
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Flow

    private func run(
        _ version: CatalogVersion, of app: CatalogApp, allowChangedHash: Bool,
        emit: @escaping @Sendable (DownloadEvent) -> Void
    ) async throws {
        let url = version.downloadURL
        // Loopback is allowed here because the callers vet it: AppOperations refuses a
        // loopback address that does not come from a loopback source.
        guard URLPolicy.isAllowed(url, allowLoopback: true) else { throw DownloadFailure.blockedURL(url.absoluteString) }
        try paths.ensure()
        let file = destination(app, version)
        guard inFlight.insert(file).inserted else { throw DownloadFailure.alreadyInProgress(file.lastPathComponent) }
        defer { inFlight.remove(file) }

        if try reuse(file, for: version, emit: emit) { return }
        let part = Self.partFile(for: file, url: url)
        // Before the part was tied to its address, a leftover could be resumed from another one.
        try? FileManager.default.removeItem(at: file.appendingPathExtension("part"))
        try await PartTransfer(transfer: transfer, maxBytes: maxBytes, emit: emit).run(url: url, part: part)
        let hash = try Hashing.sha256(ofFileAt: part)
        do {
            try verify(hash, of: version, allowChangedHash: allowChangedHash)
        } catch {
            PartTransfer.discard(part)
            throw error
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: part, to: file)
        PartTransfer.discard(part, keepingPart: true)
        emit(.finished(file: file, sha256: hash))
    }

    /// A complete file is trusted only if its hash is the one on record: a file
    /// with no record, or a different hash, is stale or foreign and is replaced.
    private func reuse(
        _ file: URL, for version: CatalogVersion, emit: @Sendable (DownloadEvent) -> Void
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let hash = try Hashing.sha256(ofFileAt: file)
        let recorded = try HashRecord.read(from: paths.hashesFile)[version.downloadURL.absoluteString]
        guard recorded == hash else {
            try FileManager.default.removeItem(at: file)
            return false
        }
        if let declared = version.sha256?.lowercased(), declared != hash {
            try FileManager.default.removeItem(at: file)
            throw DownloadFailure.hashMismatch(expected: declared, actual: hash)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
        emit(.started(expectedBytes: size))
        emit(.progress(received: size ?? 0, expected: size))
        emit(.finished(file: file, sha256: hash))
        return true
    }

    /// The published checksum first, then the first-seen record. Only a file
    /// that passes both is recorded.
    private func verify(_ hash: String, of version: CatalogVersion, allowChangedHash: Bool) throws {
        if let declared = version.sha256?.lowercased(), declared != hash {
            throw DownloadFailure.hashMismatch(expected: declared, actual: hash)
        }
        let key = version.downloadURL.absoluteString
        var records = try HashRecord.read(from: paths.hashesFile)
        if let recorded = records[key], recorded != hash {
            guard allowChangedHash else { throw DownloadFailure.hashChanged(expected: recorded, actual: hash) }
        } else if records[key] != nil {
            return
        }
        records[key] = hash
        try HashRecord.write(records, to: paths.hashesFile)
    }

    /// The partial file is named for the address it came from as well as the app and
    /// version, so a leftover from one address is never resumed against another.
    static func partFile(for file: URL, url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return file.appendingPathExtension(digest).appendingPathExtension("part")
    }

    /// Bundle id and version come from the source, so they are reduced to a safe
    /// alphabet before they become part of a file name.
    private func destination(_ app: CatalogApp, _ version: CatalogVersion) -> URL {
        let name = "\(Self.safe(app.bundleID))-\(Self.safe(version.version)).ipa"
        return paths.downloads.appendingPathComponent(name)
    }

    private static func safe(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        let cleaned = String(text.map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }
}
