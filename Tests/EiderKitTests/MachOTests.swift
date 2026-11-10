import Foundation
import XCTest
@testable import EiderKit

final class MachOPureTests: XCTestCase {
    func testVersionParsingAndOrdering() {
        XCTAssertEqual(MachOVersion("14.2.1")?.description, "14.2.1")
        XCTAssertEqual(MachOVersion("26.4")?.description, "26.4")
        XCTAssertNil(MachOVersion("x.1"))
        XCTAssertNil(MachOVersion(""))
        XCTAssertTrue(MachOVersion("14.9")! < MachOVersion("14.10")!)
    }

    func testRejectsNonMachO() {
        XCTAssertThrowsError(try MachOImage(bytes: Data("hello world, not a binary".utf8))) {
            XCTAssertEqual($0 as? MachOError, .notMachO)
        }
        let thirtyTwoBit = Data([0xCE, 0xFA, 0xED, 0xFE]) + Data(count: 60)
        XCTAssertThrowsError(try MachOImage(bytes: thirtyTwoBit)) {
            guard case .unsupported = $0 as? MachOError else { return XCTFail("expected unsupported, got \($0)") }
        }
    }

    func testJavaClassHeaderIsNotAFatFile() {
        // CAFEBABE, minor 0, major 52 (Java 8): "52 architectures" that cannot fit.
        let header = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52]) + Data(count: 100)
        XCTAssertNil(MachOFat.slices(in: header, fileSize: 4096))
    }

    func testTruncatedHeaderDoesNotCrash() {
        var bytes = Data([0xCF, 0xFA, 0xED, 0xFE])
        bytes.append(Data(count: 28))
        bytes.replaceSubrange(20..<24, with: [0xFF, 0xFF, 0, 0])   // sizeofcmds far past the data
        XCTAssertThrowsError(try MachOImage(bytes: bytes))
    }
}

final class MachOEditTests: XCTestCase {
    private func linkedPaths(_ url: URL, _ fixtures: MachOFixtures) throws -> [String] {
        try fixtures.tool("otool", ["-L", url.path]).split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " (").first ?? "" }
    }

    func testReaderAgreesWithOtoolAndVtool() throws {
        let fixtures = try MachOFixtures()
        let lib = try fixtures.dylib("libread.dylib", installName: "@rpath/libread.dylib", ["-framework", "CoreFoundation"])
        let image = try MachOFiles.readImage(at: lib)
        // otool -L lists the dylib own install name first; linkedDylibs is dependencies only.
        XCTAssertEqual(try image.linkedDylibs(), Array(try linkedPaths(lib, fixtures).dropFirst()))
        XCTAssertEqual(try image.dylibID(), "@rpath/libread.dylib")
        XCTAssertTrue(image.isARM64)
        let build = try XCTUnwrap(try image.buildVersion())
        let show = try fixtures.tool("vtool", ["-show-build", lib.path])
        XCTAssertTrue(show.contains("minos \(build.minimumOS)"), show)
        XCTAssertTrue(show.contains("sdk \(build.sdk)"), show)
        XCTAssertEqual(build.platform, 1)
    }

    func testPlatformRewriteMatchesVtoolAndStillSigns() throws {
        let fixtures = try MachOFixtures()
        let lib = try fixtures.dylib("libplat.dylib")
        let sdk = MachOVersion(major: 26, minor: 4)
        try MachOFiles.edit(at: lib) { try $0.setPlatformMacCatalyst(minimumOS: MachOVersion(major: 11, minor: 0), sdk: sdk) }
        let show = try fixtures.tool("vtool", ["-show-build", lib.path])
        XCTAssertTrue(show.contains("platform MACCATALYST"), show)
        XCTAssertTrue(show.contains("minos 11.0"), show)
        XCTAssertTrue(show.contains("sdk 26.4"), show)
        try fixtures.sign(lib)
    }

    func testOldVersionMinCommandIsReplacedByBuildVersion() throws {
        let fixtures = try MachOFixtures()
        let lib = try fixtures.dylib("libmin.dylib")
        try MachOFiles.edit(at: lib) { image in
            let build = try XCTUnwrap(try image.loadCommands().first { $0.cmd == MachOConstant.lcBuildVersion })
            var versionMin = Data()
            for field in [MachOConstant.lcVersionMinIPhoneOS, 16, MachOVersion(major: 15, minor: 0).packed, MachOVersion(major: 17, minor: 2).packed] {
                withUnsafeBytes(of: field.littleEndian) { versionMin.append(contentsOf: $0) }
            }
            try image.splice(at: build.offset, removing: build.size, inserting: versionMin, countDelta: 0)
        }
        XCTAssertEqual(try MachOFiles.readImage(at: lib).sdkVersion(), MachOVersion(major: 17, minor: 2))
        try MachOFiles.edit(at: lib) { try $0.setPlatformMacCatalyst(minimumOS: MachOVersion(major: 11, minor: 0), sdk: MachOVersion(major: 17, minor: 2)) }
        let image = try MachOFiles.readImage(at: lib)
        XCTAssertFalse(try image.loadCommands().contains { MachOConstant.versionMinCommands.contains($0.cmd) })
        let show = try fixtures.tool("vtool", ["-show-build", lib.path])
        XCTAssertTrue(show.contains("platform MACCATALYST") && show.contains("sdk 17.2"), show)
        try fixtures.sign(lib)
    }

    func testChangeLinkedDylibAndSetID() throws {
        let fixtures = try MachOFixtures()
        let dependency = try fixtures.dylib("libdep.dylib", installName: "@rpath/libdep.dylib")
        let lib = try fixtures.dylib("libuser.dylib", source: "int f(void);\nint g(void) { return f(); }\n", [dependency.path, "-Wl,-headerpad_max_install_names"])
        let target = "/System/iOSSupport/usr/lib/swift/libdep.dylib"
        try MachOFiles.edit(at: lib) {
            XCTAssertTrue(try $0.changeLinkedDylib(from: "@rpath/libdep.dylib", to: target))
            XCTAssertFalse(try $0.changeLinkedDylib(from: "@rpath/absent.dylib", to: target))
            try $0.setDylibID("@executable_path/Frameworks/libuser.dylib")
        }
        let paths = try linkedPaths(lib, fixtures)
        XCTAssertTrue(paths.contains(target), "\(paths)")
        XCTAssertFalse(paths.contains("@rpath/libdep.dylib"))
        XCTAssertEqual(try MachOFiles.readImage(at: lib).dylibID(), "@executable_path/Frameworks/libuser.dylib")
        try fixtures.sign(lib)
    }

    func testAddedLoadCommandIsLoadedByDyld() throws {
        let fixtures = try MachOFixtures()
        let marker = fixtures.url("marker.txt")
        let injected = try fixtures.dylib(
            "libinjected.dylib", installName: "@executable_path/libinjected.dylib",
            source: "#include <stdio.h>\n__attribute__((constructor)) static void up(void) { FILE *f = fopen(\"\(marker.path)\", \"w\"); if (f) { fputs(\"loaded\", f); fclose(f); } }\n"
        )
        try fixtures.sign(injected)
        let executable = try fixtures.compile("host", source: "int main(void) { return 0; }\n", [])
        try MachOFiles.edit(at: executable) {
            XCTAssertTrue(try $0.addLoadDylib("@executable_path/libinjected.dylib"))
            XCTAssertFalse(try $0.addLoadDylib("@executable_path/libinjected.dylib"), "adding twice must not duplicate")
        }
        XCTAssertEqual(try linkedPaths(executable, fixtures).filter { $0 == "@executable_path/libinjected.dylib" }.count, 1)
        try fixtures.sign(executable)
        let run = try ProcessRunner.run(executable.path)
        XCTAssertTrue(run.succeeded, run.errorLine)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "loaded", "dyld did not load the injected dylib")
    }

    func testNoRoomIsAnErrorAndLeavesTheFileUntouched() throws {
        let fixtures = try MachOFixtures()
        let lib = try fixtures.dylib("libtight.dylib", ["-Wl,-headerpad,0"])
        let before = try Data(contentsOf: lib)
        let long = "@executable_path/Frameworks/" + String(repeating: "x", count: 400) + ".dylib"
        XCTAssertThrowsError(try MachOFiles.edit(at: lib) { try $0.addLoadDylib(long) }) {
            guard case .noRoom = $0 as? MachOError else { return XCTFail("expected noRoom, got \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: lib), before)
    }

    func testCryptIDReadFromEncryptionCommand() throws {
        let fixtures = try MachOFixtures()
        let lib = try fixtures.dylib("libcrypt.dylib")
        XCTAssertNil(try MachOFiles.readImage(at: lib).cryptID())
        try MachOFiles.edit(at: lib) { image in
            var command = Data()
            for field: UInt32 in [MachOConstant.lcEncryptionInfo64, 24, 0x4000, 0x1000, 1, 0] {
                withUnsafeBytes(of: field.littleEndian) { command.append(contentsOf: $0) }
            }
            try image.splice(at: image.commandsEnd, removing: 0, inserting: command, countDelta: 1)
        }
        XCTAssertEqual(try MachOFiles.readImage(at: lib).cryptID(), 1)
    }
}

final class MachOThinTests: XCTestCase {
    private func archs(_ url: URL, _ fixtures: MachOFixtures) throws -> String {
        try fixtures.tool("lipo", ["-archs", url.path]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testFatFileIsThinnedToItsArm64Slice() throws {
        let fixtures = try MachOFixtures()
        let fat = try fixtures.compile("libfat.dylib", source: "int f(void) { return 1; }\n", ["-arch", "arm64", "-arch", "x86_64", "-dynamiclib"])
        XCTAssertEqual(MachOFiles.kind(of: fat), .fat)
        try MachOFiles.thinToArm64(at: fat)
        XCTAssertEqual(MachOFiles.kind(of: fat), .thin)
        XCTAssertEqual(try archs(fat, fixtures), "arm64")
        try MachOFiles.edit(at: fat) { try $0.addLoadDylib("@rpath/libextra.dylib") }
        try fixtures.sign(fat)
    }

    func testThinArm64IsLeftAlone() throws {
        let fixtures = try MachOFixtures()
        let lib = try fixtures.dylib("libthin.dylib")
        let before = try Data(contentsOf: lib)
        try MachOFiles.thinToArm64(at: lib)
        XCTAssertEqual(try Data(contentsOf: lib), before)
    }

    func testOtherArchitecturesAreRefused() throws {
        let fixtures = try MachOFixtures()
        let intel = try fixtures.compile("libintel.dylib", source: "int f(void) { return 1; }\n", ["-arch", "x86_64", "-dynamiclib"])
        XCTAssertThrowsError(try MachOFiles.thinToArm64(at: intel)) {
            XCTAssertEqual($0 as? MachOError, .noArm64Slice(archs: ["x86_64"]))
        }
        let e = try? fixtures.compile("libe.dylib", source: "int f(void) { return 1; }\n", ["-arch", "arm64e", "-dynamiclib"])
        guard let e else { return }
        XCTAssertThrowsError(try MachOFiles.thinToArm64(at: e)) { XCTAssertEqual($0 as? MachOError, .arm64eOnly) }
    }

    func testKindOfPlainFiles() throws {
        let fixtures = try MachOFixtures()
        let text = fixtures.url("note.txt")
        try "just text".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertEqual(MachOFiles.kind(of: text), .notMachO)
        XCTAssertEqual(MachOFiles.kind(of: fixtures.url("missing")), .notMachO)
    }
}
