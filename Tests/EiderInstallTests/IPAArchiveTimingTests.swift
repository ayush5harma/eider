import Foundation
import XCTest
@testable import EiderInstall

/// Times a repack of a ~100 MB app. Opt-in (EIDER_TIMING=1) because it writes ~300 MB.
final class IPAArchiveTimingTests: XCTestCase {
    func testRepackOfAHundredMegabyteApp() throws {
        guard ProcessInfo.processInfo.environment["EIDER_TIMING"] == "1" else {
            throw XCTSkip("Set EIDER_TIMING=1 to time a 100 MB repack.")
        }
        let fm = FileManager.default
        let root = try IPAArchive.makeWorkDirectory()
        defer { IPAArchive.removeWorkDirectory(root) }

        // Shaped like a real app: one large executable, a few frameworks, many small resources.
        let app = root.appendingPathComponent("src/Big.app", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        func blob(_ size: Int) -> Data {
            var data = Data(count: size)
            data.withUnsafeMutableBytes { buffer in
                let words = buffer.bindMemory(to: UInt64.self)
                for index in words.indices { words[index] = generator.next() }
            }
            return data
        }
        try blob(40 << 20).write(to: app.appendingPathComponent("Big"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Big").path)
        for index in 0..<8 {
            try blob(5 << 20).write(to: app.appendingPathComponent("Frameworks/F\(index).dylib"))
        }
        for index in 0..<2_000 {
            try blob(10 << 10).write(to: app.appendingPathComponent("Assets/a\(index).png"))
        }

        let ipa = root.appendingPathComponent("Big.ipa")
        let packStart = Date()
        try IPAArchive.pack(appAt: app, to: ipa)
        let packSeconds = Date().timeIntervalSince(packStart)

        let unpackStart = Date()
        _ = try IPAArchive.unpack(ipa, into: root.appendingPathComponent("out"))
        let unpackSeconds = Date().timeIntervalSince(unpackStart)

        let size = (try fm.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.int64Value ?? 0
        print(String(format: "EIDER_TIMING ipa=%.1f MB pack=%.2f s unpack=%.2f s",
                     Double(size) / 1_048_576, packSeconds, unpackSeconds))
    }
}
