import Foundation

/// The header region of one thin 64-bit little-endian Mach-O: the header, the
/// load commands, and the zero padding the linker leaves after them. Every
/// read and edit this tool needs touches only these bytes, so a multi-hundred
/// megabyte binary is never held in memory (see `MachOFiles`).
///
/// A value type: an edit that throws half way leaves the caller's copy intact.
public struct MachOImage: Sendable {
    public internal(set) var bytes: Data

    /// `bytes` must start at the Mach-O header and reach at least to the end of
    /// the load commands; it should reach the first section for edits that grow them.
    public init(bytes: Data) throws {
        guard bytes.count >= 4 else { throw MachOError.notMachO }
        self.bytes = bytes.subdata(in: bytes.startIndex..<bytes.endIndex)
        let magic = try u32(0)
        if magic != MachOConstant.magic64 {
            if MachOConstant.otherThinMagics.contains(magic) {
                throw MachOError.unsupported("only 64-bit little-endian Mach-O is handled")
            }
            throw MachOError.notMachO
        }
        guard self.bytes.count >= MachOConstant.headerSize else { throw MachOError.malformed("truncated header") }
        guard commandsEnd <= self.bytes.count else { throw MachOError.malformed("load commands run past the header region") }
    }

    // MARK: Header fields

    public var cpuType: UInt32 { (try? u32(4)) ?? 0 }
    public var cpuSubtype: UInt32 { (try? u32(8)) ?? 0 }
    public var isARM64: Bool {
        cpuType == MachOConstant.cpuTypeARM64 && cpuSubtype & MachOConstant.cpuSubtypeMask != MachOConstant.cpuSubtypeARM64E
    }

    var commandCount: Int { Int((try? u32(MachOConstant.ncmdsOffset)) ?? 0) }
    var commandsSize: Int { Int((try? u32(MachOConstant.sizeofcmdsOffset)) ?? 0) }
    var commandsEnd: Int { MachOConstant.headerSize + commandsSize }

    // MARK: Raw access

    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw MachOError.malformed("read past the header region") }
        return UInt32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }

    func u64(_ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { throw MachOError.malformed("read past the header region") }
        return UInt64(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
    }

    mutating func setU32(_ value: UInt32, at offset: Int) throws {
        guard offset >= 0, offset + 4 <= bytes.count else { throw MachOError.malformed("write past the header region") }
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
    }

    // MARK: Load commands

    public func loadCommands() throws -> [LoadCommand] {
        var result: [LoadCommand] = []
        var offset = MachOConstant.headerSize
        let end = commandsEnd
        for _ in 0..<commandCount {
            guard offset + 8 <= end else { throw MachOError.malformed("load command count runs past sizeofcmds") }
            let size = Int(try u32(offset + 4))
            guard size >= 8, offset + size <= end else { throw MachOError.malformed("load command size out of range") }
            result.append(LoadCommand(cmd: try u32(offset), offset: offset, size: size))
            offset += size
        }
        return result
    }

    /// The NUL-terminated name inside a dylib-style command (name offset at +8).
    func dylibName(of command: LoadCommand) throws -> String {
        let nameOffset = Int(try u32(command.offset + 8))
        guard nameOffset >= MachOConstant.dylibCommandSize, nameOffset < command.size else {
            throw MachOError.malformed("dylib name offset out of range")
        }
        let start = command.offset + nameOffset
        let raw = bytes.subdata(in: start..<command.offset + command.size)
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Paths of every dylib this image links, in load-command order.
    public func linkedDylibs() throws -> [String] {
        try loadCommands().filter { MachOConstant.dependencyCommands.contains($0.cmd) }.map(dylibName(of:))
    }

    /// The image's own install name (LC_ID_DYLIB), nil for an executable.
    public func dylibID() throws -> String? {
        guard let command = try loadCommands().first(where: { $0.cmd == MachOConstant.lcIDDylib }) else { return nil }
        return try dylibName(of: command)
    }

    /// The first LC_ENCRYPTION_INFO(_64) cryptid, nil when there is no such command.
    public func cryptID() throws -> UInt32? {
        let kinds = [MachOConstant.lcEncryptionInfo, MachOConstant.lcEncryptionInfo64]
        guard let command = try loadCommands().first(where: { kinds.contains($0.cmd) }), command.size >= 20 else { return nil }
        return try u32(command.offset + 16)
    }

    /// LC_BUILD_VERSION when present, else the LC_VERSION_MIN_* command.
    public func buildVersion() throws -> MachOBuildVersion? {
        let commands = try loadCommands()
        if let build = commands.first(where: { $0.cmd == MachOConstant.lcBuildVersion }), build.size >= MachOConstant.buildVersionCommandSize {
            return MachOBuildVersion(
                platform: try u32(build.offset + 8),
                minimumOS: MachOVersion(packed: try u32(build.offset + 12)),
                sdk: MachOVersion(packed: try u32(build.offset + 16))
            )
        }
        guard let min = commands.first(where: { MachOConstant.versionMinCommands.contains($0.cmd) }), min.size >= 16 else { return nil }
        return MachOBuildVersion(
            platform: nil,
            minimumOS: MachOVersion(packed: try u32(min.offset + 8)),
            sdk: MachOVersion(packed: try u32(min.offset + 12))
        )
    }

    /// The SDK a binary was linked against, read the way the legacy installer
    /// did: LC_BUILD_VERSION, else LC_VERSION_MIN_IPHONEOS only.
    public func sdkVersion() throws -> MachOVersion? {
        let commands = try loadCommands()
        if commands.contains(where: { $0.cmd == MachOConstant.lcBuildVersion }) { return try buildVersion()?.sdk }
        guard let min = commands.first(where: { $0.cmd == MachOConstant.lcVersionMinIPhoneOS }), min.size >= 16 else { return nil }
        return MachOVersion(packed: try u32(min.offset + 12))
    }

    /// How far the load commands may grow: the lowest file offset of a
    /// non-empty __TEXT section, or the end of the region read when there is
    /// none. Every segment's section table is walked so a table that runs past
    /// the commands fails here, before anything is written.
    public func commandGrowthLimit() throws -> Int {
        var lowest: Int?
        for command in try loadCommands() where command.cmd == MachOConstant.lcSegment64 {
            guard command.size >= MachOConstant.segmentCommandSize else { throw MachOError.malformed("short segment command") }
            let isText = bytes.subdata(in: command.offset + 8..<command.offset + 24).prefix { $0 != 0 }.elementsEqual(Array("__TEXT".utf8))
            let sectionCount = Int(try u32(command.offset + 64))
            guard MachOConstant.segmentCommandSize + sectionCount * MachOConstant.sectionSize <= command.size else {
                throw MachOError.malformed("section table runs past its segment command")
            }
            for index in 0..<sectionCount {
                let section = command.offset + MachOConstant.segmentCommandSize + index * MachOConstant.sectionSize
                let size = try u64(section + 40), fileOffset = Int(try u32(section + 48))
                if isText, size != 0, fileOffset != 0 { lowest = min(lowest ?? fileOffset, fileOffset) }
            }
        }
        return min(lowest ?? bytes.count, bytes.count)
    }
}
