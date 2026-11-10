import Foundation
import XCTest
@testable import EiderKit

final class EngineNeutraliseTests: XCTestCase {
    func testKeychainFixTweakIsReplacedUnderItsOwnInstallName() throws {
        let fixtures = try MachOFixtures()
        let app = fixtures.url("N.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let tweak = app.appendingPathComponent("Frameworks/[sideloadKeychainFix].dylib")
        let original = "@rpath/[sideloadKeychainFix].dylib"
        _ = try fixtures.dylib("tweak.dylib", installName: original, source: "int hooked_secitem(void) { return 7; }\n")
        try FileManager.default.moveItem(at: fixtures.url("tweak.dylib"), to: tweak)
        let bystander = app.appendingPathComponent("Frameworks/libother.dylib")
        _ = try fixtures.dylib("other.dylib", installName: "@rpath/libother.dylib")
        try FileManager.default.moveItem(at: fixtures.url("other.dylib"), to: bystander)
        let bystanderBefore = try Data(contentsOf: bystander)

        // The neutraliser as build-shims.sh makes it: Catalyst, with header room for a longer name.
        let sdk = try fixtures.tool("--sdk", ["macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = fixtures.url("noop.c")
        try "void ipa_neutralised(void) {}\n".write(to: source, atomically: true, encoding: .utf8)
        let neutraliser = fixtures.url("libneutral.dylib")
        try fixtures.tool("clang", [
            "-target", "arm64-apple-ios14.0-macabi", "-isysroot", sdk, "-dynamiclib", "-Wl,-headerpad_max_install_names",
            "-install_name", "@executable_path/Frameworks/libneutral.dylib", "-o", neutraliser.path, source.path,
        ])

        let replaced = try BundleConverter(app: app).neutraliseKeychainFixes { neutraliser }

        XCTAssertEqual(replaced, ["Frameworks/[sideloadKeychainFix].dylib"])
        XCTAssertEqual(try MachOFiles.readImage(at: tweak).dylibID(), original, "dyld looks the tweak up by this name")
        let symbols = try fixtures.tool("nm", ["-gU", tweak.path])
        XCTAssertFalse(symbols.contains("hooked_secitem"), symbols)
        XCTAssertEqual(try Data(contentsOf: bystander), bystanderBefore, "other libraries are left alone")
        try fixtures.sign(tweak)
    }
}
