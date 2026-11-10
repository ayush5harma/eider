import Foundation
import XCTest
@testable import EiderKit

final class EngineArchiveTests: XCTestCase {
    private func installer(_ scratch: EngineScratch, cap: UInt64 = Installer.defaultMaxUncompressedBytes) throws -> Installer {
        let shims = ShimLocator(environment: [ShimLocator.overrideVariable: try scratch.placeholderShims().path], executableURL: nil, resourceURL: nil)
        return Installer(paths: EiderPaths(home: scratch.url("home")), shims: shims, maxUncompressedBytes: cap)
    }

    private func options(_ scratch: EngineScratch) -> InstallOptions { InstallOptions(destination: scratch.url("apps")) }

    private func assertFailure(_ code: InstallFailure.Code, _ ipa: URL, _ installer: Installer, _ options: InstallOptions, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await installer.install(ipa: ipa, options: options)
            XCTFail("expected \(code)", file: file, line: line)
        } catch let failure as InstallFailure {
            XCTAssertEqual(failure.code, code, failure.message, file: file, line: line)
            XCTAssertFalse(failure.message.isEmpty, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testListingIsParsedWithSpacesInNames() {
        let listing = """
        Archive:  x.ipa
        Zip file size: 680 bytes, number of entries: 3
        drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-11 01:54 Payload/A B.app/
        lrwxr-xr-x  3.0 unx        4 bx stor 26-Nov-11 01:54 Payload/A B.app/link
        -rw-r--r--  3.0 unx     1234 tx defN 26-Nov-11 01:54 Payload/A B.app/Info.plist
        3 files, 1238 bytes uncompressed, 6 bytes compressed:  0.0%
        """
        let entries = IPAExtractor.parseListing(listing)
        XCTAssertEqual(entries.map(\.path), ["Payload/A B.app/", "Payload/A B.app/link", "Payload/A B.app/Info.plist"])
        XCTAssertEqual(entries.map(\.isSymlink), [false, true, false])
        XCTAssertEqual(entries.last?.size, 1234)
        XCTAssertTrue(IPAExtractor.isAppInfoPlist(entries[2]))
    }

    func testTextFileIsNotAnIPA() async throws {
        let scratch = try EngineScratch()
        let notZip = scratch.url("x.ipa")
        try "hello".write(to: notZip, atomically: true, encoding: .utf8)
        await assertFailure(.notAnIPA, notZip, try installer(scratch), options(scratch))
    }

    func testZipWithoutAppIsNotAnIPA() async throws {
        let scratch = try EngineScratch()
        let ipa = scratch.url("x.ipa")
        try EngineZip.write(entries: [("readme.txt", Data("hi".utf8), EngineZip.file)], to: ipa)
        await assertFailure(.notAnIPA, ipa, try installer(scratch), options(scratch))
    }

    func testParentDirectoryEntryIsRefusedBeforeUnpacking() async throws {
        let scratch = try EngineScratch()
        let ipa = scratch.url("evil.ipa")
        try EngineZip.write(entries: [
            ("Payload/Evil.app/Info.plist", Data("x".utf8), EngineZip.file),
            ("Payload/Evil.app/../../../escape.txt", Data("x".utf8), EngineZip.file),
        ], to: ipa)
        await assertFailure(.unsafeArchive, ipa, try installer(scratch), options(scratch))
    }

    func testAbsoluteEntryIsRefused() async throws {
        let scratch = try EngineScratch()
        let ipa = scratch.url("abs.ipa")
        try EngineZip.write(entries: [
            ("Payload/Evil.app/Info.plist", Data("x".utf8), EngineZip.file),
            ("/tmp/eider-escape.txt", Data("x".utf8), EngineZip.file),
        ], to: ipa)
        await assertFailure(.unsafeArchive, ipa, try installer(scratch), options(scratch))
    }

    func testWritingThroughASymlinkIsRefused() async throws {
        let scratch = try EngineScratch()
        let ipa = scratch.url("link.ipa")
        try EngineZip.write(entries: [
            ("Payload/Evil.app/Info.plist", Data("x".utf8), EngineZip.file),
            ("Payload/Evil.app/out", Data("/tmp".utf8), EngineZip.symlink),
            ("Payload/Evil.app/out/planted", Data("x".utf8), EngineZip.file),
        ], to: ipa)
        await assertFailure(.unsafeArchive, ipa, try installer(scratch), options(scratch))
    }

    func testOversizedArchiveIsRefused() async throws {
        let scratch = try EngineScratch()
        let ipa = scratch.url("big.ipa")
        try EngineZip.write(entries: [("Payload/Big.app/Info.plist", Data(count: 4096), EngineZip.file)], to: ipa)
        await assertFailure(.tooLarge, ipa, try installer(scratch, cap: 1024), options(scratch))
    }

    func testSymlinkPointingOutsideAfterExtractionIsRefused() throws {
        let scratch = try EngineScratch()
        let root = scratch.url("x")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Payload/A.app"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Payload/A.app/ok").path, withDestinationPath: "Info.plist")
        XCTAssertNoThrow(try IPAExtractor().rejectEscapingSymlinks(in: root))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Payload/A.app/bad").path, withDestinationPath: "../../../../etc/hosts")
        XCTAssertThrowsError(try IPAExtractor().rejectEscapingSymlinks(in: root)) {
            XCTAssertEqual(($0 as? InstallFailure)?.code, .unsafeArchive)
        }
    }

    func testUnsupportedAndInvalidOptionsFailBeforeAnyWork() async throws {
        let scratch = try EngineScratch()
        let ipa = scratch.url("none.ipa")   // never opened: the options are refused first
        var reset = options(scratch)
        reset.resetData = true
        await assertFailure(.unsupportedOption, ipa, try installer(scratch), reset)
        var source = options(scratch)
        source.extraDylibs = [scratch.url("extra.c")]
        await assertFailure(.unsupportedOption, ipa, try installer(scratch), source)
        var missing = options(scratch)
        missing.extraDylibs = [scratch.url("absent.dylib")]
        await assertFailure(.invalidOption, ipa, try installer(scratch), missing)
    }

    func testMissingShimsAreReportedBeforeUnpacking() async throws {
        let scratch = try EngineScratch()
        let empty = scratch.url("noshims")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let shims = ShimLocator(environment: [ShimLocator.overrideVariable: empty.path], executableURL: nil, resourceURL: nil)
        let installer = Installer(paths: EiderPaths(home: scratch.url("home")), shims: shims)
        await assertFailure(.missingShim, scratch.url("none.ipa"), installer, options(scratch))
    }
}

final class EngineUnitTests: XCTestCase {
    func testMacIdiomIsAppendedNeverReplaced() {
        XCTAssertEqual(InstallRun.familiesWithMac(nil), [1, 2, 6])
        XCTAssertEqual(InstallRun.familiesWithMac([1]), [1, 6])
        XCTAssertEqual(InstallRun.familiesWithMac([2, 6]), [2, 6])
    }

    func testBundleIdAndNameValidation() {
        XCTAssertTrue(BundleIdentity.isPlausibleBundleID("com.example.App-1_x"))
        XCTAssertFalse(BundleIdentity.isPlausibleBundleID("../../Documents"))
        XCTAssertFalse(BundleIdentity.isPlausibleBundleID("a/b"))
        XCTAssertFalse(BundleIdentity.isPlausibleBundleID("a..b"))
        XCTAssertFalse(BundleIdentity.isPlausibleBundleID(""))
        XCTAssertEqual(BundleIdentity.fileSafe("A/B:C"), "A_B_C")
        XCTAssertFalse(BundleIdentity.isPlausibleExecutableName("../x"))
    }

    func testOptionsRoundTripThroughJSON() throws {
        var options = InstallOptions(macIdiom: true, extraDylibs: [URL(fileURLWithPath: "/tmp/libx.dylib")], force: true)
        options.sourceURL = URL(string: "https://example.com/app.ipa")
        let decoded = try JSONDecoder().decode(InstallOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
        XCTAssertEqual(InstallOptions().destination.path, "/Applications")
        XCTAssertTrue(InstallOptions().keychainShim)
    }

    func testShimLookupOrder() throws {
        let scratch = try EngineScratch()
        let bin = scratch.url("prefix/bin"), share = scratch.url("prefix/share/eider/shims")
        let resources = scratch.url("App.app/Contents/Resources"), bundled = resources.appendingPathComponent("shims")
        let override = scratch.url("override")
        for folder in [bin, share, bundled, override] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let name = Shim.groups.rawValue
        let executable = bin.appendingPathComponent("eider")

        try Data("bundle".utf8).write(to: bundled.appendingPathComponent(name))
        var locator = ShimLocator(environment: [:], executableURL: executable, resourceURL: resources)
        XCTAssertEqual(try locator.url(for: .groups).path, bundled.appendingPathComponent(name).path)

        try Data("share".utf8).write(to: share.appendingPathComponent(name))
        locator = ShimLocator(environment: [:], executableURL: executable, resourceURL: resources)
        XCTAssertEqual(try locator.url(for: .groups).resolvingSymlinksInPath().path, share.appendingPathComponent(name).resolvingSymlinksInPath().path)

        try Data("override".utf8).write(to: override.appendingPathComponent(name))
        locator = ShimLocator(environment: [ShimLocator.overrideVariable: override.path], executableURL: executable, resourceURL: resources)
        XCTAssertEqual(try locator.url(for: .groups).path, override.appendingPathComponent(name).path)

        XCTAssertThrowsError(try locator.url(for: .gles)) { XCTAssertEqual(($0 as? InstallFailure)?.code, .missingShim) }
    }

    func testEventFractionIsClamped() {
        XCTAssertEqual(InstallEvent(step: .sign, message: "x", fraction: 3).fraction, 1)
        XCTAssertEqual(InstallEvent(step: .sign, message: "x", fraction: -1).fraction, 0)
    }
}

/// Runs the whole pipeline on a tiny IPA built from clang fixtures, with the
/// real shims when `build/shims` exists (Scripts/build-shims.sh); the full
/// launch-and-observe proof is Scripts/engine-e2e.sh.
final class EngineEncryptedTests: XCTestCase {
    func testEncryptedBinaryIsRefusedAndNothingIsInstalled() async throws {
        let fixtures = try MachOFixtures()
        let scratch = try EngineScratch()
        let app = fixtures.url("stage/Payload/Locked.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let executable = try fixtures.compile("Locked", source: "int main(void) { return 0; }\n", [])
        try FileManager.default.copyItem(at: executable, to: app.appendingPathComponent("Locked"))
        try MachOFiles.edit(at: app.appendingPathComponent("Locked")) { image in
            var command = Data()
            for field: UInt32 in [MachOConstant.lcEncryptionInfo64, 24, 0x4000, 0x1000, 1, 0] {
                withUnsafeBytes(of: field.littleEndian) { command.append(contentsOf: $0) }
            }
            try image.splice(at: image.commandsEnd, removing: 0, inserting: command, countDelta: 1)
        }
        let info = ["CFBundleIdentifier": "test.locked", "CFBundleExecutable": "Locked", "CFBundleName": "Locked"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let ipa = scratch.url("locked.ipa")
        let staged = Process()
        staged.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        staged.arguments = ["-qry", ipa.path, "Payload"]
        staged.currentDirectoryURL = fixtures.url("stage")
        try staged.run()
        staged.waitUntilExit()

        let shims = ShimLocator(environment: [ShimLocator.overrideVariable: try scratch.placeholderShims().path], executableURL: nil, resourceURL: nil)
        let installer = Installer(paths: EiderPaths(home: scratch.url("home")), shims: shims)
        let destination = scratch.url("apps")
        do {
            _ = try await installer.install(ipa: ipa, options: InstallOptions(destination: destination))
            XCTFail("an encrypted app must be refused")
        } catch let failure as InstallFailure {
            XCTAssertEqual(failure.code, .encrypted)
            XCTAssertTrue(failure.message.contains("Locked"), failure.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Locked.app").path))
        let library = try await LibraryStore(paths: EiderPaths(home: scratch.url("home"))).all()
        XCTAssertTrue(library.isEmpty)
    }
}
