import Foundation

/// Reads the code signature superblob of a thin 64-bit Mach-O, so tests can
/// check the CMS with openssl. macOS codesign cannot: it will not evaluate a
/// chain to a CA the user has not trusted, and reports "Authority=(unavailable)"
/// and "invalid signature" for any such signature, Apple codesign's own
/// included (measured 2026-11-28 by signing the same dylib with codesign from
/// a temporary keychain holding the test identity: errSecInternalComponent).
struct SignatureBlobs {
    /// Blob type to blob bytes, header included.
    let blobs: [UInt32: Data]

    static let codeDirectory: UInt32 = 0
    static let alternateCodeDirectory: UInt32 = 0x1000
    static let cms: UInt32 = 0x10000

    init(machO url: URL) throws {
        let data = try Data(contentsOf: url)
        func le32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        guard le32(0) == 0xFEEDFACF else { throw Failure(reason: "not a thin 64-bit Mach-O: \(url.lastPathComponent)") }
        var offset = 32
        var signature: Range<Int>?
        for _ in 0..<le32(16) {
            if le32(offset) == 0x1D { // LC_CODE_SIGNATURE
                let start = Int(le32(offset + 8))
                signature = start..<start + Int(le32(offset + 12))
            }
            offset += Int(le32(offset + 4))
        }
        guard let signature else { throw Failure(reason: "no LC_CODE_SIGNATURE in \(url.lastPathComponent)") }
        let superblob = data.subdata(in: signature)
        func be32(_ offset: Int) -> UInt32 {
            superblob[offset..<offset + 4].withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        var blobs: [UInt32: Data] = [:]
        for index in 0..<Int(be32(8)) {
            let type = be32(12 + 8 * index)
            let start = Int(be32(16 + 8 * index))
            blobs[type] = superblob.subdata(in: start..<start + Int(be32(start + 4)))
        }
        self.blobs = blobs
    }

    struct Failure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }
}
