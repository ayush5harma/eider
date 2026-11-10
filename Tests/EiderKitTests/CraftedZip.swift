import Foundation
import XCTest

/// Builds hostile archives with test-time python3 (never run by the product):
/// the names, symlinks and lying size fields that /usr/bin/zip and the stored
/// writer in EngineZip cannot produce with real CRCs.
enum CraftedZip {
    struct Entry {
        var name: String
        var text: String = ""
        var symlink = false
        /// Inflates to this many zero bytes (deflate: a few KB on disk).
        var zeros = 0
        /// What the central directory and local header claim as uncompressed size.
        var claimedSize: Int?
    }

    private static let script = #"""
    import json, struct, sys, zipfile
    spec = json.loads(sys.argv[1])
    with zipfile.ZipFile(spec["out"], "w", zipfile.ZIP_DEFLATED) as z:
        for e in spec["entries"]:
            info = zipfile.ZipInfo(e["name"], (2026, 11, 11, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (0o120777 if e["symlink"] else 0o100644) << 16
            z.writestr(info, b"\0" * e["zeros"] if e["zeros"] else e["text"].encode())
    claims = {e["name"]: e["claimedSize"] for e in spec["entries"] if e["claimedSize"] is not None}
    if claims:
        data = bytearray(open(spec["out"], "rb").read())
        at = data.find(b"PK\x01\x02")
        while at != -1:
            nlen = struct.unpack_from("<H", data, at + 28)[0]
            name = bytes(data[at + 46:at + 46 + nlen]).decode()
            if name in claims:
                struct.pack_into("<I", data, at + 24, claims[name])
                local = struct.unpack_from("<I", data, at + 42)[0]
                struct.pack_into("<I", data, local + 22, claims[name])
            at = data.find(b"PK\x01\x02", at + 4)
        open(spec["out"], "wb").write(data)
    """#

    static func write(_ entries: [Entry], to url: URL) throws {
        let spec: [String: Any] = [
            "out": url.path,
            "entries": entries.map { entry -> [String: Any] in
                var item: [String: Any] = ["name": entry.name, "text": entry.text, "symlink": entry.symlink, "zeros": entry.zeros]
                item["claimedSize"] = entry.claimedSize ?? NSNull()
                return item
            },
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: spec), as: UTF8.self)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -I: no user site, no current-directory imports.
        process.arguments = ["python3", "-I", "-c", script, json]
        let failure = Pipe()
        process.standardError = failure
        do { try process.run() } catch { throw XCTSkip("python3 is not available: \(error)") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: failure.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw XCTSkip("python3 could not build the archive: \(message)")
        }
    }
}
