import Foundation
import XCTest
import ZIPFoundation
@testable import EiderInstall

final class IPAArchiveTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("EiderInstallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A small .app with an executable, a nested framework symlink and a resource.
    private func makeApp(named name: String = "Demo") throws -> URL {
        let fm = FileManager.default
        let app = scratch.appendingPathComponent("src/\(name).app", isDirectory: true)
        let versions = app.appendingPathComponent("Frameworks/Lib.framework/Versions/A", isDirectory: true)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        let exec = app.appendingPathComponent(name)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: exec)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)
        try Data("plist".utf8).write(to: app.appendingPathComponent("Info.plist"))
        try Data("lib".utf8).write(to: versions.appendingPathComponent("Lib"))
        try fm.createSymbolicLink(
            atPath: app.appendingPathComponent("Frameworks/Lib.framework/Versions/Current").path,
            withDestinationPath: "A")
        try fm.createSymbolicLink(
            atPath: app.appendingPathComponent("Frameworks/Lib.framework/Lib").path,
            withDestinationPath: "Versions/Current/Lib")
        return app
    }

    func testRoundTripKeepsExecutableBitsAndSymlinks() throws {
        let app = try makeApp()
        let ipa = scratch.appendingPathComponent("Demo.ipa")
        try IPAArchive.pack(appAt: app, to: ipa)

        let names = try Archive(url: ipa, accessMode: .read).map(\.path)
        XCTAssertTrue(names.contains("Payload/Demo.app/Demo"), "\(names)")
        XCTAssertTrue(names.allSatisfy { $0 == "Payload/" || $0.hasPrefix("Payload/Demo.app/") }, "\(names)")

        let work = scratch.appendingPathComponent("work", isDirectory: true)
        let unpacked = try IPAArchive.unpack(ipa, into: work)
        XCTAssertEqual(unpacked.lastPathComponent, "Demo.app")
        XCTAssertEqual(unpacked.deletingLastPathComponent().lastPathComponent, "Payload")

        let fm = FileManager.default
        let mode = try fm.attributesOfItem(atPath: unpacked.appendingPathComponent("Demo").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o755)
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: unpacked.appendingPathComponent("Frameworks/Lib.framework/Lib").path),
            "Versions/Current/Lib")
        XCTAssertEqual(
            try String(contentsOf: unpacked.appendingPathComponent("Frameworks/Lib.framework/Lib"), encoding: .utf8),
            "lib")
    }

    func testPathTraversalEntryIsRefused() throws {
        let ipa = scratch.appendingPathComponent("evil.ipa")
        try makeZip(ipa) { archive in
            try addFile(archive, path: "Payload/Evil.app/Info.plist")
            try addFile(archive, path: "Payload/Evil.app/../../../escaped.txt")
        }

        let work = scratch.appendingPathComponent("work", isDirectory: true)
        XCTAssertThrowsError(try IPAArchive.unpack(ipa, into: work)) { error in
            guard case IPAArchive.Error.unsafeEntry = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("escaped.txt").path))
    }

    func testAbsoluteEntryIsRefused() throws {
        let ipa = scratch.appendingPathComponent("abs.ipa")
        try makeZip(ipa) { archive in
            try addFile(archive, path: "Payload/A.app/Info.plist")
            try addFile(archive, path: "/tmp/eider-abs.txt")
        }
        XCTAssertThrowsError(try IPAArchive.unpack(ipa, into: scratch.appendingPathComponent("w")))
    }

    func testSymlinkPointingOutsideIsRefused() throws {
        let ipa = scratch.appendingPathComponent("link.ipa")
        try makeZip(ipa) { archive in
            try addFile(archive, path: "Payload/L.app/Info.plist")
            let target = Data("../../../../etc".utf8)
            try archive.addEntry(with: "Payload/L.app/out", type: .symlink, uncompressedSize: Int64(target.count),
                                 provider: { position, size in target.subdata(in: Int(position)..<Int(position) + size) })
        }
        XCTAssertThrowsError(try IPAArchive.unpack(ipa, into: scratch.appendingPathComponent("w")))
    }

    func testArchiveWithoutExactlyOneAppIsRefused() throws {
        let none = scratch.appendingPathComponent("none.ipa")
        try makeZip(none) { try addFile($0, path: "Payload/readme.txt") }
        XCTAssertThrowsError(try IPAArchive.unpack(none, into: scratch.appendingPathComponent("w1"))) { error in
            XCTAssertEqual(error as? IPAArchive.Error, .appCount(0))
        }

        let two = scratch.appendingPathComponent("two.ipa")
        try makeZip(two) { archive in
            try addFile(archive, path: "Payload/A.app/Info.plist")
            try addFile(archive, path: "Payload/B.app/Info.plist")
        }
        XCTAssertThrowsError(try IPAArchive.unpack(two, into: scratch.appendingPathComponent("w2"))) { error in
            XCTAssertEqual(error as? IPAArchive.Error, .appCount(2))
        }
    }

    func testPrepareSignedIPACallsTheSignerOnTheAppAndCleansUp() async throws {
        let app = try makeApp(named: "Signed")
        let ipa = scratch.appendingPathComponent("in.ipa")
        try IPAArchive.pack(appAt: app, to: ipa)

        var signedApp: URL?
        let output = try await LocalInstaller.prepareSignedIPA(from: ipa) { appURL in
            signedApp = appURL
            try Data("signature".utf8).write(to: appURL.appendingPathComponent("_CodeSignature"))
        }
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }

        XCTAssertEqual(signedApp?.lastPathComponent, "Signed.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: signedApp!.path), "unpack dir left behind")
        let names = try Archive(url: output, accessMode: .read).map(\.path)
        XCTAssertTrue(names.contains("Payload/Signed.app/_CodeSignature"), "\(names)")
    }

    /// The archive is closed (and its central directory flushed) when this returns.
    private func makeZip(_ url: URL, _ build: (Archive) throws -> Void) throws {
        try build(try Archive(url: url, accessMode: .create))
    }

    private func addFile(_ archive: Archive, path: String) throws {
        let data = Data("x".utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
    }
}
