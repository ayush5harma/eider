import Foundation

/// Unpacks an IPA with /usr/bin/unzip after reading its table of contents:
/// nothing in the archive is trusted, so unsafe entries are refused before a
/// byte is written, and symlinks are checked again afterwards.
struct IPAExtractor {
    static let unzip = "/usr/bin/unzip"
    static let defaultMaxUncompressedBytes: UInt64 = 8 << 30

    struct Entry: Equatable {
        let path: String
        let isSymlink: Bool
        let size: UInt64
    }

    var maxUncompressedBytes: UInt64 = defaultMaxUncompressedBytes

    // MARK: Listing

    /// `unzip -Z` prints one line per entry: mode, version, OS, size, flags,
    /// method, date, time, then the name (which may contain spaces).
    static func parseListing(_ listing: String) -> [Entry] {
        listing.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, let mode = fields.first, mode.count >= 10,
                  "-dlcbps".contains(mode.first ?? "?"), let size = UInt64(fields[3]) else { return nil }
            return Entry(path: String(fields[8]), isSymlink: mode.first == "l", size: size)
        }
    }

    func list(_ ipa: URL) throws -> [Entry] {
        let result: ProcessResult
        do { result = try ProcessRunner.run(Self.unzip, ["-Z", ipa.path]) } catch {
            throw InstallFailure(.extractionFailed, "Could not run /usr/bin/unzip: \(error)")
        }
        guard result.succeeded else {
            throw InstallFailure(.notAnIPA, "\(ipa.lastPathComponent) is not a readable zip archive, so it is not an .ipa.")
        }
        let entries = Self.parseListing(result.output)
        guard entries.contains(where: Self.isAppInfoPlist) else {
            throw InstallFailure(.notAnIPA, "\(ipa.lastPathComponent) has no Payload/<App>.app/Info.plist inside, so it is not an .ipa.")
        }
        return entries
    }

    static func isAppInfoPlist(_ entry: Entry) -> Bool {
        let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
    }

    // MARK: Checks before extracting

    func validate(_ entries: [Entry]) throws {
        for entry in entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            if entry.path.hasPrefix("/") || components.contains("..") || entry.path.utf8.contains(0) {
                throw InstallFailure(
                    .unsafeArchive,
                    "The archive contains an entry that would be written outside its own folder (\(entry.path)). It was not unpacked."
                )
            }
        }
        // A symlink followed by entries below it could redirect those writes.
        for link in entries where link.isSymlink {
            let prefix = link.path.hasSuffix("/") ? link.path : link.path + "/"
            if entries.contains(where: { $0.path.hasPrefix(prefix) }) {
                throw InstallFailure(.unsafeArchive, "The archive writes files through a symlink (\(link.path)). It was not unpacked.")
            }
        }
        let total = entries.reduce(UInt64(0)) { $0 &+ $1.size }
        if total > maxUncompressedBytes {
            let gigabytes = Double(total) / Double(1 << 30), cap = Double(maxUncompressedBytes) / Double(1 << 30)
            throw InstallFailure(
                .tooLarge,
                String(format: "The archive would unpack to %.1f GB, more than the %.1f GB limit. It was not unpacked.", gigabytes, cap)
            )
        }
    }

    // MARK: Extract

    /// Unpack into `directory` (new and empty) and return the single `.app` under Payload.
    func extract(_ ipa: URL, into directory: URL) throws -> URL {
        try validate(try list(ipa))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try ProcessRunner.run(Self.unzip, ["-q", "-o", ipa.path, "-d", directory.path])
        guard result.succeeded else {
            throw InstallFailure(.extractionFailed, "Unpacking \(ipa.lastPathComponent) failed: \(result.errorLine)")
        }
        try rejectEscapingSymlinks(in: directory)
        return try appBundle(in: directory)
    }

    func appBundle(in directory: URL) throws -> URL {
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? [])
            .filter { $0.hasSuffix(".app") }.sorted()
        guard apps.count == 1, let app = apps.first else {
            throw InstallFailure(.badBundle, "Expected exactly one .app under Payload/, found \(apps.count).")
        }
        return payload.appendingPathComponent(app, isDirectory: true)
    }

    /// Symlinks resolved as far as the file system can: resolvingSymlinksInPath leaves
    /// a path that does not exist unresolved (/var stays /var, not /private/var), which
    /// would make a dangling link inside the bundle look like it points outside.
    static func resolvedPath(_ url: URL) -> String {
        var existing = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let base = existing.resolvingSymlinksInPath().path
        return tail.isEmpty ? base : base + "/" + tail.joined(separator: "/")
    }

    func rejectEscapingSymlinks(in directory: URL) throws {
        let root = Self.resolvedPath(directory)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        for case let item as URL in walker {
            guard (try? item.resourceValues(forKeys: Set(keys)).isSymbolicLink) == true,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) else { continue }
            let target = Self.resolvedPath(URL(fileURLWithPath: destination, relativeTo: item.deletingLastPathComponent()).standardizedFileURL)
            guard target == root || target.hasPrefix(root + "/") else {
                throw InstallFailure(.unsafeArchive, "The archive contains a symlink that points outside itself (\(item.lastPathComponent) -> \(destination)).")
            }
        }
    }
}
