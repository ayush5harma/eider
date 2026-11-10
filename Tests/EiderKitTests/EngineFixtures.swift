import EiderKit
import Foundation

/// A scratch directory removed when the test object goes away.
final class EngineScratch {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eider-engine-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// A shims folder whose files exist but are empty: enough for the lookup,
    /// not enough to link, which is what the refusal tests need.
    func placeholderShims() throws -> URL {
        let folder = url("shims")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for shim in Shim.allCases { try Data().write(to: folder.appendingPathComponent(shim.rawValue)) }
        return folder
    }
}

/// Writes a stored (uncompressed) zip with exactly the entry names given, which
/// /usr/bin/zip refuses to do for "../" and absolute names. CRCs are zero: the
/// tests only list and refuse these archives, they never extract them.
enum EngineZip {
    static func write(entries: [(name: String, contents: Data, mode: UInt32)], to url: URL) throws {
        var archive = Data(), central = Data()
        func put32(_ value: UInt32, _ data: inout Data) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16, _ data: inout Data) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = UInt32(archive.count)
            put32(0x0403_4B50, &archive); put16(20, &archive); put16(0, &archive); put16(0, &archive)
            put16(0, &archive); put16(0x21, &archive); put32(0, &archive)
            put32(UInt32(entry.contents.count), &archive); put32(UInt32(entry.contents.count), &archive)
            put16(UInt16(name.count), &archive); put16(0, &archive)
            archive.append(name); archive.append(entry.contents)
            put32(0x0201_4B50, &central); put16(0x031E, &central); put16(20, &central); put16(0, &central); put16(0, &central)
            put16(0, &central); put16(0x21, &central); put32(0, &central)
            put32(UInt32(entry.contents.count), &central); put32(UInt32(entry.contents.count), &central)
            put16(UInt16(name.count), &central); put16(0, &central); put16(0, &central); put16(0, &central); put16(0, &central)
            put32(entry.mode << 16, &central); put32(offset, &central)
            central.append(name)
        }
        var end = Data()
        put32(0x0605_4B50, &end); put16(0, &end); put16(0, &end)
        put16(UInt16(entries.count), &end); put16(UInt16(entries.count), &end)
        put32(UInt32(central.count), &end); put32(UInt32(archive.count), &end); put16(0, &end)
        try (archive + central + end).write(to: url)
    }

    static let file: UInt32 = 0o100644
    static let symlink: UInt32 = 0o120777
}
