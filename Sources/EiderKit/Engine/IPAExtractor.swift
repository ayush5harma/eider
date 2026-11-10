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

    /// A symlink as the archive declares it, with the target already read and vetted.
    private struct Link {
        let path: String
        let target: String
    }

    /// Unpack into `directory` (new and empty) and return the single `.app` under Payload.
    ///
    /// Symlinks are never handed to unzip: the archive is extracted without them and
    /// each is created here afterwards, only when its target is relative and has no
    /// ".." component. With no link on disk while files are written, nothing can be
    /// written through one, whatever the spelling of the entry's name (case variants
    /// on a case-insensitive volume, "./", doubled slashes). The size cap is enforced
    /// on the bytes written, because the central directory is attacker-controlled.
    func extract(_ ipa: URL, into directory: URL) throws -> URL {
        let entries = try list(ipa)
        try validate(entries)
        let links = try entries.filter(\.isSymlink).map { Link(path: $0.path, target: try linkTarget(of: $0, in: ipa)) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try unpack(ipa, into: directory, leavingOut: links.map(\.path))
        try createSymlinks(links, in: directory)
        try rejectEscapingSymlinks(in: directory)
        return try appBundle(in: directory)
    }

    private func unpack(_ ipa: URL, into directory: URL, leavingOut excluded: [String]) throws {
        var arguments = ["-q", "-o", "-d", directory.path, ipa.path]
        if !excluded.isEmpty { arguments += ["-x"] + excluded.map(Self.literalPattern) }
        let cap = maxUncompressedBytes
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(Self.unzip, arguments, stopWhen: { Self.bytesWritten(under: directory) > cap })
        } catch {
            throw InstallFailure(.extractionFailed, "Could not run /usr/bin/unzip: \(error)")
        }
        if result.stopped || Self.bytesWritten(under: directory) > cap {
            try? FileManager.default.removeItem(at: directory)
            throw InstallFailure(
                .tooLarge,
                "The archive unpacked to more than the \(Self.gigabytes(cap)) GB limit (its own size fields said less). Unpacking was stopped and what was written was removed."
            )
        }
        guard result.succeeded else {
            throw InstallFailure(.extractionFailed, "Unpacking \(ipa.lastPathComponent) failed: \(result.errorLine)")
        }
    }

    private static func gigabytes(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / Double(1 << 30)) }

    /// Total size of the regular files below `directory`, as the file system reports it now.
    static func bytesWritten(under directory: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total &+= UInt64(values.fileSize ?? 0)
        }
        return total
    }

    /// unzip treats names on its command line as wildcard patterns.
    static func literalPattern(_ name: String) -> String {
        var escaped = ""
        for character in name {
            if "\\*?[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    // MARK: Symlinks

    private static let maxLinkTargetBytes = 1024

    /// Reads a symlink entry's target (its stored data) and refuses anything that is not
    /// a relative path without a ".." component.
    private func linkTarget(of entry: Entry, in ipa: URL) throws -> String {
        func refuse(_ why: String) -> InstallFailure {
            InstallFailure(.unsafeArchive, "The archive contains a symlink \(why) (\(entry.path)). It was not unpacked.")
        }
        guard entry.path.hasPrefix("Payload/"), !entry.path.hasSuffix("/") else { throw refuse("outside Payload") }
        guard entry.size > 0, entry.size <= UInt64(Self.maxLinkTargetBytes) else { throw refuse("with an unreasonable target") }
        let result = try ProcessRunner.run(Self.unzip, ["-p", ipa.path, Self.literalPattern(entry.path)])
        guard result.succeeded, UInt64(result.standardOutput.count) == entry.size,
              let target = String(data: result.standardOutput, encoding: .utf8),
              !target.isEmpty, !target.hasPrefix("/"), !target.utf8.contains(0)
        else { throw refuse("with an absolute or unreadable target") }
        guard !target.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw refuse("that points to a parent directory (\(target))")
        }
        return target
    }

    private func createSymlinks(_ links: [Link], in directory: URL) throws {
        let root = Self.resolvedPath(directory)
        for link in links {
            let location = directory.appendingPathComponent(link.path)
            let parent = location.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let resolvedParent = Self.resolvedPath(parent)
            // attributesOfItem does not follow a final symlink, and on a case-insensitive
            // volume it finds an extracted entry that differs from the link's name only in case.
            guard resolvedParent == root || resolvedParent.hasPrefix(root + "/"),
                  (try? FileManager.default.attributesOfItem(atPath: location.path)) == nil
            else { throw InstallFailure(.unsafeArchive, "The archive's symlink \(link.path) collides with another entry or sits below a link. It was not unpacked.") }
            do { try FileManager.default.createSymbolicLink(atPath: location.path, withDestinationPath: link.target) } catch {
                throw InstallFailure(.extractionFailed, "Could not create the symlink \(link.path): \(error.localizedDescription)")
            }
        }
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
