import Foundation

/// One architecture inside a universal ("fat") Mach-O.
public struct FatSlice: Sendable, Equatable {
    public let cpuType: UInt32
    public let cpuSubtype: UInt32
    public let offset: UInt64
    public let size: UInt64

    public var isARM64: Bool {
        cpuType == MachOConstant.cpuTypeARM64 && cpuSubtype & MachOConstant.cpuSubtypeMask != MachOConstant.cpuSubtypeARM64E
    }
    public var isARM64E: Bool {
        cpuType == MachOConstant.cpuTypeARM64 && cpuSubtype & MachOConstant.cpuSubtypeMask == MachOConstant.cpuSubtypeARM64E
    }

    /// A readable name for an error message.
    public var architectureName: String { MachOArchitecture.name(cpuType: cpuType, cpuSubtype: cpuSubtype) }
}

public enum MachOArchitecture {
    public static func name(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        let subtype = cpuSubtype & MachOConstant.cpuSubtypeMask
        switch cpuType {
        case MachOConstant.cpuTypeARM64: return subtype == MachOConstant.cpuSubtypeARM64E ? "arm64e" : "arm64"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        case 0x0000_000C: return "arm"
        default: return String(format: "cpu 0x%x", cpuType)
        }
    }
}

public enum MachOFat {
    /// Largest fat header read; real ones list a handful of architectures.
    static let maxArchitectures = 32

    /// The slices of a fat file, or nil when `header` is not a plausible one.
    /// Java class files begin with the same CAFEBABE, so the table is checked
    /// against the file size, as `file` does.
    public static func slices(in header: Data, fileSize: UInt64) -> [FatSlice]? {
        guard header.count >= 8 else { return nil }
        let bytes = [UInt8](header)
        func be32(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func be64(_ offset: Int) -> UInt64 {
            bytes[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
        }
        let magic = be32(0)
        let is64 = magic == MachOConstant.fatMagic64
        guard magic == MachOConstant.fatMagic || is64 else { return nil }
        let count = Int(be32(4))
        let entrySize = is64 ? 32 : 20
        guard (1...maxArchitectures).contains(count), 8 + count * entrySize <= bytes.count else { return nil }
        var result: [FatSlice] = []
        for index in 0..<count {
            let base = 8 + index * entrySize
            let slice = FatSlice(
                cpuType: be32(base), cpuSubtype: be32(base + 4),
                offset: is64 ? be64(base + 8) : UInt64(be32(base + 8)),
                size: is64 ? be64(base + 16) : UInt64(be32(base + 12))
            )
            let (end, overflow) = slice.offset.addingReportingOverflow(slice.size)
            guard slice.size >= MachOConstant.headerSize.asUInt64, !overflow, end <= fileSize else { return nil }
            result.append(slice)
        }
        return result
    }

    /// The slice to keep: a plain arm64, else the error the legacy installer gave.
    public static func arm64Slice(of slices: [FatSlice]) throws -> FatSlice {
        if let slice = slices.first(where: { $0.isARM64 }) { return slice }
        if slices.contains(where: { $0.isARM64E }) { throw MachOError.arm64eOnly }
        throw MachOError.noArm64Slice(archs: slices.map(\.architectureName))
    }
}

private extension Int {
    var asUInt64: UInt64 { UInt64(self) }
}
