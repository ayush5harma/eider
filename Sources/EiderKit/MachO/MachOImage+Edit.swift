import Foundation

/// The edits install_name_tool, vtool and the legacy injector made, in pure
/// Swift. Each one rewrites load commands in place and is bounded by the
/// padding before the first section: no room is an error, never a corrupt file.
extension MachOImage {
    // MARK: Primitive

    /// Replace `removed` bytes of the load-command area at `offset` with `new`
    /// and shift what follows. Growth must fit in the zero padding.
    mutating func splice(at offset: Int, removing removed: Int, inserting new: Data, countDelta: Int) throws {
        let end = commandsEnd
        let delta = new.count - removed
        if delta > 0 {
            let limit = try commandGrowthLimit()
            guard end + delta <= limit else { throw MachOError.noRoom(needed: delta, available: max(limit - end, 0)) }
            guard bytes.subdata(in: end..<end + delta).allSatisfy({ $0 == 0 }) else {
                throw MachOError.malformed("the bytes after the load commands are not padding")
            }
        }
        var rebuilt = bytes.subdata(in: 0..<offset)
        rebuilt.append(new)
        rebuilt.append(bytes.subdata(in: offset + removed..<end))
        if delta < 0 { rebuilt.append(Data(count: -delta)) }
        rebuilt.append(bytes.subdata(in: max(end, end + delta)..<bytes.count))
        bytes = rebuilt
        try setU32(UInt32(commandCount + countDelta), at: MachOConstant.ncmdsOffset)
        try setU32(UInt32(commandsSize + delta), at: MachOConstant.sizeofcmdsOffset)
    }

    static func dylibCommand(
        cmd: UInt32, name: String, timestamp: UInt32 = 2, currentVersion: UInt32 = 0x10000, compatibilityVersion: UInt32 = 0x10000
    ) throws -> Data {
        guard !name.isEmpty, !name.utf8.contains(0) else { throw MachOError.malformed("bad dylib name") }
        let nameBytes = Data(name.utf8) + Data([0])
        let size = (MachOConstant.dylibCommandSize + nameBytes.count + 7) & ~7
        var command = Data()
        for field in [cmd, UInt32(size), UInt32(MachOConstant.dylibCommandSize), timestamp, currentVersion, compatibilityVersion] {
            withUnsafeBytes(of: field.littleEndian) { command.append(contentsOf: $0) }
        }
        command.append(nameBytes)
        command.append(Data(count: size - command.count))
        return command
    }

    // MARK: Dylib edits

    /// Point every dependency on `old` at `new` (install_name_tool -change).
    /// Returns whether anything changed.
    @discardableResult
    public mutating func changeLinkedDylib(from old: String, to new: String) throws -> Bool {
        var changed = false
        while let command = try loadCommands().first(where: {
            MachOConstant.dependencyCommands.contains($0.cmd) && (try? dylibName(of: $0)) == old
        }) {
            let replacement = try Self.dylibCommand(
                cmd: command.cmd, name: new,
                timestamp: try u32(command.offset + 12),
                currentVersion: try u32(command.offset + 16),
                compatibilityVersion: try u32(command.offset + 20)
            )
            try splice(at: command.offset, removing: command.size, inserting: replacement, countDelta: 0)
            changed = true
            if old == new { break }
        }
        return changed
    }

    /// Set the image's own install name (install_name_tool -id).
    public mutating func setDylibID(_ name: String) throws {
        guard let command = try loadCommands().first(where: { $0.cmd == MachOConstant.lcIDDylib }) else {
            throw MachOError.malformed("no LC_ID_DYLIB to rename")
        }
        let replacement = try Self.dylibCommand(
            cmd: MachOConstant.lcIDDylib, name: name,
            timestamp: try u32(command.offset + 12),
            currentVersion: try u32(command.offset + 16),
            compatibilityVersion: try u32(command.offset + 20)
        )
        try splice(at: command.offset, removing: command.size, inserting: replacement, countDelta: 0)
    }

    /// Append an LC_LOAD_DYLIB for `path` after the existing commands, as the
    /// legacy injector did. Idempotent: returns false when it is already linked.
    @discardableResult
    public mutating func addLoadDylib(_ path: String) throws -> Bool {
        if try linkedDylibs().contains(path) { return false }
        let command = try Self.dylibCommand(cmd: MachOConstant.lcLoadDylib, name: path)
        try splice(at: commandsEnd, removing: 0, inserting: command, countDelta: 1)
        return true
    }

    // MARK: Platform

    /// vtool -set-build-version maccatalyst <minimumOS> <sdk> -replace: an
    /// existing LC_BUILD_VERSION is updated in place (its tool entries kept),
    /// an old LC_VERSION_MIN_* is removed and a fresh LC_BUILD_VERSION appended.
    public mutating func setPlatformMacCatalyst(minimumOS: MachOVersion, sdk: MachOVersion) throws {
        for command in try loadCommands().reversed() where MachOConstant.versionMinCommands.contains(command.cmd) {
            try splice(at: command.offset, removing: command.size, inserting: Data(), countDelta: -1)
        }
        if let build = try loadCommands().first(where: { $0.cmd == MachOConstant.lcBuildVersion }) {
            guard build.size >= MachOConstant.buildVersionCommandSize else { throw MachOError.malformed("short LC_BUILD_VERSION") }
            try setU32(MachOConstant.platformMacCatalyst, at: build.offset + 8)
            try setU32(minimumOS.packed, at: build.offset + 12)
            try setU32(sdk.packed, at: build.offset + 16)
            return
        }
        var command = Data()
        let fields = [MachOConstant.lcBuildVersion, UInt32(MachOConstant.buildVersionCommandSize), MachOConstant.platformMacCatalyst, minimumOS.packed, sdk.packed, 0]
        for field in fields { withUnsafeBytes(of: field.littleEndian) { command.append(contentsOf: $0) } }
        try splice(at: commandsEnd, removing: 0, inserting: command, countDelta: 1)
    }
}
