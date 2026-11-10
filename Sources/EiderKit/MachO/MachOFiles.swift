import Foundation

/// File-level Mach-O work: classify, thin to arm64, read, edit in place.
/// Edits read and rewrite only the header region, so the size of the binary
/// does not matter; thinning streams the arm64 slice to a sibling file.
public enum MachOFiles {
    public enum Kind: Sendable, Equatable { case thin, fat, notMachO }

    /// Enough for a fat header listing the most architectures `MachOFat` accepts.
    private static let sniffLength = 8 + MachOFat.maxArchitectures * 32
    /// The header region read for an edit: room for the commands and padding of
    /// every binary seen so far (a typical one pads to 16 KiB), bounded so a
    /// hostile sizeofcmds cannot ask for the whole file.
    private static let regionMinimum = 64 * 1024
    private static let regionMaximum = 8 * 1024 * 1024
    private static let copyChunk = 4 * 1024 * 1024

    // MARK: Classify

    public static func kind(of url: URL) -> Kind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .notMachO }
        defer { try? handle.close() }
        return (try? kind(of: handle)) ?? .notMachO
    }

    private static func kind(of handle: FileHandle) throws -> Kind {
        guard let head = try handle.read(upToCount: sniffLength), head.count >= 4 else { return .notMachO }
        let little = head.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        if little == MachOConstant.magic64 || MachOConstant.otherThinMagics.contains(little) { return .thin }
        let size = try handle.seekToEnd()
        return MachOFat.slices(in: head, fileSize: size) == nil ? .notMachO : .fat
    }

    // MARK: Thin

    /// Reduce the file to its plain arm64 slice, in place. A thin arm64 file is
    /// left alone; arm64e-only and other architectures are errors.
    public static func thinToArm64(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: sniffLength) ?? Data()
        guard let slices = MachOFat.slices(in: head, fileSize: size) else {
            try requireThinARM64(head)
            return
        }
        let slice = try MachOFat.arm64Slice(of: slices)
        let temporary = url.appendingPathExtension("thin")
        try? FileManager.default.removeItem(at: temporary)
        try copy(slice, from: handle, to: temporary)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private static func requireThinARM64(_ head: Data) throws {
        guard head.count >= 12 else { throw MachOError.notMachO }
        let magic = head.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        guard magic == MachOConstant.magic64 else {
            guard MachOConstant.otherThinMagics.contains(magic) else { throw MachOError.notMachO }
            throw MachOError.noArm64Slice(archs: [])
        }
        let field = { (at: Int) in head[at..<at + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        let slice = FatSlice(cpuType: field(4), cpuSubtype: field(8), offset: 0, size: 0)
        if slice.isARM64 { return }
        if slice.isARM64E { throw MachOError.arm64eOnly }
        throw MachOError.noArm64Slice(archs: [slice.architectureName])
    }

    private static func copy(_ slice: FatSlice, from source: FileHandle, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw MachOError.malformed("cannot create \(destination.lastPathComponent)")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try source.seek(toOffset: slice.offset)
        var remaining = slice.size
        while remaining > 0 {
            let want = Int(min(UInt64(copyChunk), remaining))
            guard let chunk = try source.read(upToCount: want), !chunk.isEmpty else {
                throw MachOError.malformed("slice runs past the end of the file")
            }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    // MARK: Read and edit

    /// The header region of the file's arm64 slice (the file itself when thin).
    public static func readImage(at url: URL) throws -> MachOImage {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: sniffLength) ?? Data()
        let offset: UInt64
        if let slices = MachOFat.slices(in: head, fileSize: size) {
            offset = try MachOFat.arm64Slice(of: slices).offset
        } else {
            offset = 0
        }
        return try loadImage(from: handle, at: offset)
    }

    /// Edit a thin file's header region in place. Nothing is written when the
    /// edit throws or changes nothing.
    public static func edit(at url: URL, _ body: (inout MachOImage) throws -> Void) throws {
        try ensureOwnerWritable(url)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var image = try loadImage(from: handle, at: 0)
        let original = image.bytes
        try body(&image)
        guard image.bytes != original else { return }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: image.bytes)
    }

    private static func loadImage(from handle: FileHandle, at offset: UInt64) throws -> MachOImage {
        try handle.seek(toOffset: offset)
        guard let header = try handle.read(upToCount: MachOConstant.headerSize), header.count == MachOConstant.headerSize else {
            throw MachOError.notMachO
        }
        let commandsSize = header[header.startIndex + MachOConstant.sizeofcmdsOffset..<header.startIndex + MachOConstant.sizeofcmdsOffset + 4]
            .enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let want = min(max(regionMinimum, MachOConstant.headerSize + commandsSize + 4096), regionMaximum)
        try handle.seek(toOffset: offset)
        return try MachOImage(bytes: try handle.read(upToCount: want) ?? Data())
    }

    private static func ensureOwnerWritable(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? Int, permissions & 0o200 == 0 else { return }
        try FileManager.default.setAttributes([.posixPermissions: permissions | 0o200], ofItemAtPath: url.path)
    }
}
