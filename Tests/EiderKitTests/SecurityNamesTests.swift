import Foundation
import XCTest
@testable import EiderKit

/// Finding 7: control, format and bidi characters in names and versions, and
/// names that would make a bad destination.
final class SecurityNamesTests: XCTestCase {
    private let esc = "\u{1B}", rlo = "\u{202E}", zwsp = "\u{200B}", isolate = "\u{2066}"

    func testSanitizedRemovesControlFormatAndBidiCharacters() {
        XCTAssertEqual(DisplayText.sanitized("Pay\(rlo)fdp.app\(esc)[31m\(zwsp)\0 \u{2028}x"), "Payfdp.app[31m x")
        XCTAssertEqual(DisplayText.sanitized("\(isolate)\(zwsp)  "), "")
        XCTAssertEqual(DisplayText.sanitized("Caf\u{E9} \u{1F600}"), "Caf\u{E9} \u{1F600}", "ordinary text is untouched")
        XCTAssertEqual(DisplayText.sanitizedProse("line one\nline\(rlo) two\(esc)\t!"), "line one\nline two\t!")
    }

    func testEscapingShowsWhatSanitizingWouldRemoveAndKeepsRowBreaks() {
        XCTAssertEqual(DisplayText.escapingControls("a\(esc)[2Jb\(rlo)\r\nc"), "a\\u{1B}[2Jb\\u{202E}\\u{D}\nc")
        XCTAssertEqual(DisplayText.escapingControls("plain"), "plain")
    }

    // MARK: From the IPA

    private func identity(_ plist: [String: Any], options: InstallOptions = InstallOptions()) throws -> BundleIdentity {
        let scratch = try EngineScratch()
        let file = scratch.url("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
        return try BundleIdentity(plist: try InfoPlist(url: file), options: options)
    }

    private func base(_ extra: [String: Any]) -> [String: Any] {
        ["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Exec"].merging(extra) { $1 }
    }

    func testTheShownNameIsCleanedAndFallsBackToTheBundleID() throws {
        let cleaned = try identity(base(["CFBundleDisplayName": "My\(rlo) App\(esc)"]))
        XCTAssertEqual(cleaned.displayName, "My App")
        XCTAssertEqual(cleaned.name, "My App")

        let invisible = try identity(base(["CFBundleDisplayName": "\(zwsp)\(rlo)", "CFBundleName": "\(esc)"]))
        XCTAssertEqual(invisible.name, "Exec", "the next candidate with anything visible left")

        let nothing = try identity(base(["CFBundleExecutable": "E", "CFBundleDisplayName": "\(zwsp)"]), options: InstallOptions(displayName: "\(rlo)"))
        XCTAssertEqual(nothing.name, "E")
    }

    func testTheDestinationNameIsNeverEmptyHiddenOrLong() throws {
        for shown in ["...", ".", "..", ".hidden", "   ", "/", "a/b:c"] {
            let identity = try identity(base(["CFBundleDisplayName": shown]))
            XCTAssertFalse(identity.name.isEmpty, shown)
            XCTAssertFalse(identity.name.hasPrefix("."), "\(shown) -> \(identity.name)")
            XCTAssertFalse(identity.name.contains("/") || identity.name.contains(":"), identity.name)
        }
        XCTAssertEqual(try identity(base(["CFBundleDisplayName": ".hidden"])).name, "hidden")
        XCTAssertEqual(try identity(base(["CFBundleDisplayName": "..."])).name, "com.example.app", "nothing left: the bundle id")
        let long = try identity(base(["CFBundleDisplayName": String(repeating: "x", count: 400)]))
        XCTAssertEqual(long.name.count, BundleIdentity.maxFileNameLength)
    }

    func testAnExecutableNameWithControlCharactersOrASlashIsRefused() throws {
        for executable in ["Ex\(esc)ec", "Ex\(rlo)ec", "Ex\nec", "a/b", "..", String(repeating: "x", count: 300)] {
            XCTAssertThrowsError(try identity(base(["CFBundleExecutable": executable])), executable) {
                XCTAssertEqual(($0 as? InstallFailure)?.code, .unsafeName, "\($0)")
            }
        }
        XCTAssertNoThrow(try identity(base(["CFBundleExecutable": "My App-1_x"])))
    }

    func testTheMinimumOSVersionIsCleaned() throws {
        XCTAssertEqual(try identity(base(["MinimumOSVersion": "14.0\(esc)\(rlo)"])).minimumOS, "14.0")
    }

    // MARK: From the catalog

    func testCatalogNamesAndVersionsAreCleanedAtTheModelBoundary() throws {
        let json = """
        {"name":"Src\\u202E","apps":[
          {"name":"Cool\\u001b[31m App\\u202E","bundleIdentifier":"com.cool","developerName":"Dev\\u200b","subtitle":"s\\u0000",
           "localizedDescription":"one\\ntwo\\u202e","versions":[{"version":"1.0\\u001b","buildVersion":"7\\u202e","downloadURL":"https://example.com/a.ipa","localizedDescription":"n\\nm\\u0007"}]},
          {"name":"\\u200b\\u202e","bundleIdentifier":"com.blank","versions":[{"version":"2","downloadURL":"https://example.com/b.ipa"}]}
        ]}
        """
        let source = try SourceParser.parse(data: Data(json.utf8), from: CatalogFixtures.sourceURL)
        XCTAssertEqual(source.name, "Src")
        let cool = try XCTUnwrap(source.apps.first)
        XCTAssertEqual(cool.name, "Cool[31m App")
        XCTAssertEqual(cool.developerName, "Dev")
        XCTAssertEqual(cool.subtitle, "s")
        XCTAssertEqual(cool.description, "one\ntwo")
        XCTAssertEqual(cool.versions[0].version, "1.0")
        XCTAssertEqual(cool.versions[0].build, "7")
        XCTAssertEqual(cool.versions[0].notes, "n\nm")
        XCTAssertEqual(source.apps[1].name, "com.blank", "nothing visible left: the bundle id")

        let playCover = Data(#"[{"bundleID":"com.pc","name":"P\u001bC","version":"3‮","link":"https://example.com/p.ipa"}]"#.utf8)
        let pc = try SourceParser.parse(data: playCover, from: CatalogFixtures.sourceURL)
        XCTAssertEqual(pc.apps.first?.name, "PC")
        XCTAssertEqual(pc.apps.first?.versions.first?.version, "3")
    }
}
