import Foundation

/// What can go wrong reading or editing a Mach-O. The engine turns these into
/// `InstallFailure`s that name the file.
public enum MachOError: Error, Equatable, CustomStringConvertible {
    case notMachO
    case unsupported(String)
    case malformed(String)
    case noArm64Slice(archs: [String])
    case arm64eOnly
    case noRoom(needed: Int, available: Int)

    public var description: String {
        switch self {
        case .notMachO: return "not a Mach-O file"
        case .unsupported(let what): return "unsupported Mach-O: \(what)"
        case .malformed(let what): return "malformed Mach-O: \(what)"
        case .noArm64Slice(let archs):
            return "no arm64 slice (architectures: \(archs.isEmpty ? "unknown" : archs.joined(separator: ", ")))"
        case .arm64eOnly: return "only an arm64e slice, which this tool has not been exercised on"
        case .noRoom(let needed, let available):
            return "no room in the header for \(needed) more bytes of load commands (\(available) bytes of padding)"
        }
    }
}

/// A dotted version packed the way Mach-O stores it: major in the top 16
/// bits, then one byte each for minor and patch.
public struct MachOVersion: Comparable, Sendable, CustomStringConvertible, Equatable {
    public let packed: UInt32

    public init(packed: UInt32) { self.packed = packed }

    public init(major: Int, minor: Int, patch: Int = 0) {
        packed = UInt32(major) << 16 | UInt32(minor) << 8 | UInt32(patch)
    }

    /// "14", "14.2" or "14.2.1"; anything else is nil.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let numbers = parts.compactMap { $0 }
        guard numbers[0] < 0x10000, numbers.dropFirst().allSatisfy({ $0 < 256 }) else { return nil }
        self.init(
            major: numbers[0],
            minor: numbers.count > 1 ? numbers[1] : 0,
            patch: numbers.count > 2 ? numbers[2] : 0
        )
    }

    public var description: String {
        let major = packed >> 16, minor = (packed >> 8) & 0xFF, patch = packed & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: MachOVersion, rhs: MachOVersion) -> Bool { lhs.packed < rhs.packed }
}

/// One load command: its command number and where it sits in the image.
public struct LoadCommand: Sendable, Equatable {
    public let cmd: UInt32
    public let offset: Int
    public let size: Int
}

/// The platform stamp of a binary: LC_BUILD_VERSION, or the older
/// LC_VERSION_MIN_* that predates it (then `platform` is nil).
public struct MachOBuildVersion: Sendable, Equatable {
    public let platform: UInt32?
    public let minimumOS: MachOVersion
    public let sdk: MachOVersion
}

enum MachOConstant {
    static let magic64: UInt32 = 0xFEED_FACF
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatMagic64: UInt32 = 0xCAFE_BABF
    /// Mach-O flavours this tool does not handle: 32-bit in either byte order, and 64-bit big endian.
    static let otherThinMagics: Set<UInt32> = [0xFEED_FACE, 0xCEFA_EDFE, 0xCFFA_EDFE]

    static let headerSize = 32
    static let ncmdsOffset = 16
    static let sizeofcmdsOffset = 20

    static let cpuTypeARM64: UInt32 = 0x0100_000C
    static let cpuSubtypeMask: UInt32 = 0x00FF_FFFF
    static let cpuSubtypeARM64E: UInt32 = 2

    static let lcSegment64: UInt32 = 0x19
    static let lcIDDylib: UInt32 = 0x0D
    static let lcLoadDylib: UInt32 = 0x0C
    /// Every command that names a dylib the image depends on.
    static let dependencyCommands: Set<UInt32> = [0x0C, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]
    static let lcBuildVersion: UInt32 = 0x32
    /// LC_VERSION_MIN_MACOSX, _IPHONEOS, _TVOS, _WATCHOS.
    static let versionMinCommands: Set<UInt32> = [0x24, 0x25, 0x2F, 0x30]
    static let lcVersionMinIPhoneOS: UInt32 = 0x25
    static let lcEncryptionInfo: UInt32 = 0x21
    static let lcEncryptionInfo64: UInt32 = 0x2C

    static let platformMacCatalyst: UInt32 = 6
    static let dylibCommandSize = 24
    static let buildVersionCommandSize = 24
    static let segmentCommandSize = 72
    static let sectionSize = 80
}
