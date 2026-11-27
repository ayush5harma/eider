import Foundation
import ZIPFoundation

/// Unpacks an IPA into a work directory and packs a `.app` back into an IPA.
///
/// ZIPFoundation's `extract(_:to:)` does not check that an entry's destination stays inside
/// the target directory (its own documentation says so), so every entry path is validated
/// here before anything is written. Symlink targets are checked by ZIPFoundation against the
/// work directory.
public enum IPAArchive {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// An entry whose path is absolute, contains `..`, or would land outside the work directory.
        case unsafeEntry(String)
        /// The archive does not hold exactly one `Payload/<name>.app`.
        case appCount(Int)
        /// The item handed to `pack` is not a `.app` directory.
        case notAnApp(String)

        public var description: String {
            switch self {
            case .unsafeEntry(let path): return "The IPA has an unsafe entry: \(path)"
            case .appCount(let count): return "The IPA must hold exactly one Payload app; it holds \(count)."
            case .notAnApp(let path): return "Not an .app directory: \(path)"
            }
        }
    }

    /// 1 MiB chunks instead of ZIPFoundation's 16 KiB default: fewer reads and writes per file,
    /// which is most of the cost when nothing is compressed.
    static let chunkSize = 1 << 20

    /// A fresh directory under the temporary directory for one unpack or repack.
    /// The caller removes it with `removeWorkDirectory(_:)`.
    public static func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EiderInstall", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func removeWorkDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Extracts `ipa` into `directory` (created if needed) and returns the `Payload/<name>.app` URL.
    /// On failure the partly extracted content is removed again.
    public static func unpack(_ ipa: URL, into directory: URL) throws -> URL {
        let archive = try Archive(url: ipa, accessMode: .read)
        let entries = Array(archive)
        let apps = Set(entries.compactMap { appName(in: $0.path) })
        guard apps.count == 1, let appName = apps.first else { throw Error.appCount(apps.count) }
        for entry in entries { try validate(entry.path) }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        do {
            for entry in entries {
                let destination = root.appendingPathComponent(entry.path)
                try ensureContained(destination, in: root, entry: entry.path)
                _ = try archive.extract(entry, to: destination, bufferSize: chunkSize, symlinksValidWithin: root)
            }
        } catch {
            for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: item)
            }
            throw error
        }
        return root.appendingPathComponent("Payload", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    /// Writes `app` to `ipa` as `Payload/<name>.app`, entries stored without compression by
    /// default. POSIX permissions and symlinks are kept (ZIPFoundation records both from lstat).
    public static func pack(appAt app: URL, to ipa: URL,
                            compression: CompressionMethod = .none) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard app.pathExtension == "app",
              fm.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Error.notAnApp(app.path)
        }
        if fm.fileExists(atPath: ipa.path) { try fm.removeItem(at: ipa) }
        let archive = try Archive(url: ipa, accessMode: .create)
        let prefix = "Payload/" + app.lastPathComponent
        try archive.addEntry(with: "Payload/", type: .directory, uncompressedSize: Int64(0),
                             permissions: 0o755, provider: { _, _ in Data() })
        try archive.addEntry(with: prefix + "/", fileURL: app, compressionMethod: compression,
                             bufferSize: chunkSize)
        for relative in try relativePaths(under: app) {
            try archive.addEntry(with: prefix + "/" + relative, fileURL: app.appendingPathComponent(relative),
                                 compressionMethod: compression, bufferSize: chunkSize)
        }
    }

    /// The `.app` directory name an entry belongs to, if it sits under `Payload/<name>.app`.
    static func appName(in path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Payload", parts[1].hasSuffix(".app"), parts[1] != ".app" else {
            return nil
        }
        return String(parts[1])
    }

    static func validate(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { throw Error.unsafeEntry(path) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0 == ".." }) else { throw Error.unsafeEntry(path) }
    }

    /// The nearest existing ancestor of `url`, with symlinks resolved, must be inside `root`.
    /// This catches a write through a directory symlink extracted earlier.
    private static func ensureContained(_ url: URL, in root: URL, entry: String) throws {
        var ancestor = url.deletingLastPathComponent()
        let fm = FileManager.default
        while !fm.fileExists(atPath: ancestor.path), ancestor.path.count > root.path.count {
            ancestor = ancestor.deletingLastPathComponent()
        }
        let resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == root.path || resolved.hasPrefix(root.path + "/") else { throw Error.unsafeEntry(entry) }
    }

    /// Every item under `directory`, depth first, without following symlinks into directories.
    private static func relativePaths(under directory: URL) throws -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        func walk(_ relative: String) throws {
            let url = relative.isEmpty ? directory : directory.appendingPathComponent(relative)
            for name in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                let child = relative.isEmpty ? name : relative + "/" + name
                result.append(child)
                let attributes = try fm.attributesOfItem(atPath: directory.appendingPathComponent(child).path)
                if attributes[.type] as? FileAttributeType == .typeDirectory { try walk(child) }
            }
        }
        try walk("")
        return result
    }
}
