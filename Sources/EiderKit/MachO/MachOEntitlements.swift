import Foundation

/// Reads the entitlements an executable was signed with, straight from its
/// code signature: LC_CODE_SIGNATURE points at a SuperBlob (big endian) whose
/// index lists the entitlements blob, an XML plist. Pure file reading, so the
/// engine needs no developer tools (no codesign, no otool). Every offset and
/// length is checked against the slice and the blob before it is used, and
/// anything that does not add up yields nil: the input is an untrusted IPA.
public enum MachOEntitlements {
    static let lcCodeSignature: UInt32 = 0x1D
    static let superBlobMagic = 0xFADE_0CC0
    static let entitlementsBlobMagic = 0xFADE_7171
    static let entitlementsSlot = 5
    /// A signature is a few MiB at most (mostly the code-hash table), so a larger claim is corrupt or hostile.
    static let maxSignatureBytes = 64 * 1024 * 1024
    /// Real signatures hold under ten blobs.
    static let maxBlobCount = 64
    static let superBlobHeaderSize = 12
    static let blobIndexEntrySize = 8
    static let blobHeaderSize = 8

    /// The entitlements of the file's arm64 slice, nil when it is unsigned, has
    /// none, or any part of the signature is malformed.
    public static func read(at url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let extent = try? MachOFiles.arm64Extent(of: handle),
              let image = try? MachOFiles.loadImage(from: handle, at: extent.offset),
              let command = try? image.loadCommands().first(where: { $0.cmd == lcCodeSignature }),
              command.size >= 16,
              let dataOffset = try? image.u32(command.offset + 8),
              let dataSize = try? image.u32(command.offset + 12) else { return nil }
        let (start, overflow) = UInt64(dataOffset).addingReportingOverflow(extent.offset)
        guard !overflow, dataSize > 0, Int(dataSize) <= maxSignatureBytes,
              UInt64(dataOffset) + UInt64(dataSize) <= extent.size else { return nil }
        guard (try? handle.seek(toOffset: start)) != nil,
              let signature = try? handle.read(upToCount: Int(dataSize)), signature.count == Int(dataSize) else { return nil }
        return entitlements(inSignature: signature)
    }

    /// The entitlements plist inside a code-signature SuperBlob.
    static func entitlements(inSignature signature: Data) -> [String: Any]? {
        let bytes = [UInt8](signature)
        func be32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        guard be32(0) == superBlobMagic, let length = be32(4), let count = be32(8),
              length <= bytes.count, (0...maxBlobCount).contains(count) else { return nil }
        let indexEnd = superBlobHeaderSize + count * blobIndexEntrySize
        guard indexEnd <= length else { return nil }
        for index in 0..<count {
            let entry = superBlobHeaderSize + index * blobIndexEntrySize
            guard be32(entry) == entitlementsSlot, let offset = be32(entry + 4) else { continue }
            guard offset >= indexEnd, offset + blobHeaderSize <= length,
                  be32(offset) == entitlementsBlobMagic, let blobLength = be32(offset + 4),
                  blobLength >= blobHeaderSize, offset + blobLength <= length else { return nil }
            let from = signature.startIndex + offset + blobHeaderSize
            let plist = signature.subdata(in: from..<signature.startIndex + offset + blobLength)
            return (try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)) as? [String: Any]
        }
        return nil
    }
}
