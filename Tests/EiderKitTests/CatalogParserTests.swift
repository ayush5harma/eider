import XCTest
@testable import EiderKit

final class CatalogParserTests: XCTestCase {
    func testStandardAltStoreSource() throws {
        let source = try CatalogFixtures.parse("altstore-standard.json")
        XCTAssertEqual(source.format, .altStore)
        XCTAssertEqual(source.name, "Example Repo")
        XCTAssertEqual(source.identifier, "com.example.repo")
        XCTAssertEqual(source.iconURL?.absoluteString, "https://example.com/repo/icon.png")
        XCTAssertEqual(source.website?.absoluteString, "https://example.com")
        XCTAssertEqual(source.tintColor, "#112233")
        XCTAssertTrue(source.warnings.isEmpty, "\(source.warnings)")

        let app = try XCTUnwrap(source.apps.first)
        XCTAssertEqual(app.bundleID, "com.example.alpha")
        XCTAssertEqual(app.developerName, "Dev One")
        XCTAssertEqual(app.description, "Alpha does things.")
        XCTAssertEqual(app.category, "utilities")
        XCTAssertEqual(app.screenshots.map(\.lastPathComponent), ["a1.png", "a2.png"])
        XCTAssertEqual(app.versions.map(\.version), ["1.1", "1.0"], "newest first")
        XCTAssertEqual(app.latest?.version, "1.1")

        let latest = try XCTUnwrap(app.latest)
        XCTAssertEqual(latest.build, "2")
        XCTAssertEqual(latest.size, 2048, "size arrives as a string")
        XCTAssertEqual(latest.maxOSVersion, "17.9")
        XCTAssertEqual(latest.sha256, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        let fractional = Date.utc(2024, 3, 4, 10, 20, 30).addingTimeInterval(0.123)
        XCTAssertEqual(try XCTUnwrap(latest.date).timeIntervalSince1970, fractional.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(app.versions[1].date, Date.utc(2024, 1, 2, 3, 4, 5))
    }

    func testNewsIsParsed() throws {
        let news = try XCTUnwrap(CatalogFixtures.parse("altstore-standard.json").news.first)
        XCTAssertEqual(news.identifier, "n1")
        XCTAssertEqual(news.title, "Launch")
        XCTAssertEqual(news.date, Date.utc(2024, 5, 6), "yyyy-MM-dd reads as midnight UTC")
        XCTAssertEqual(news.imageURL?.absoluteString, "https://example.com/repo/news.png")
        XCTAssertEqual(news.appID, "com.example.alpha")
    }

    func testLegacyFlatAppBecomesOneVersion() throws {
        let source = try CatalogFixtures.parse("altstore-legacy.json")
        let app = try XCTUnwrap(source.apps.first)
        XCTAssertEqual(app.versions.count, 1)
        let version = try XCTUnwrap(app.latest)
        XCTAssertEqual(version.version, "2.5")
        XCTAssertEqual(version.date, Date.utc(2023, 11, 30))
        XCTAssertEqual(version.notes, "Legacy notes")
        XCTAssertEqual(version.size, 4096)
        XCTAssertEqual(app.screenshots.count, 2)
        XCTAssertEqual(source.name, "Legacy Repo")
    }

    func testSloppySourceKeepsGoodAppAndSkipsTheRestWithWarnings() throws {
        let source = try CatalogFixtures.parse("altstore-sloppy.json")
        XCTAssertEqual(source.apps.map(\.bundleID), ["com.example.good"])
        let text = source.warnings.joined(separator: "\n")
        XCTAssertTrue(text.contains("No Bundle"), text)
        XCTAssertTrue(text.contains("com.example.noname"), text)
        XCTAssertTrue(text.contains("com.example.nodl"), text)
        XCTAssertTrue(text.contains("com.example.http"), text)
        XCTAssertTrue(text.contains("not an object"), text)
    }

    func testSloppyVersionsAreNormalised() throws {
        let app = try XCTUnwrap(CatalogFixtures.parse("altstore-sloppy.json").apps.first)
        XCTAssertEqual(app.versions.map(\.version), ["4", "3", "2"], "ordered by date, newest first")
        XCTAssertEqual(app.versions[0].size, 5000, "float size")
        XCTAssertNil(app.versions[1].size, "garbage size is dropped, not fatal")
        XCTAssertNil(app.versions[1].sha256, "non-hex sha256 is ignored")
        XCTAssertEqual(app.versions[0].date, Date.utc(2024, 6, 1, 12))
        XCTAssertEqual(app.versions[1].date, Date.utc(2024, 2, 1), "zone-less timestamp reads as UTC")
        XCTAssertEqual(app.versions[2].date, Date.utc(2023, 12, 31, 18, 30), "+0530 offset")
        XCTAssertEqual(app.versions[2].downloadURL.absoluteString, "https://example.com/rel/g2.ipa")
        XCTAssertNil(app.iconURL, "javascript: URL is dropped")
        XCTAssertEqual(app.screenshots.map(\.lastPathComponent), ["g1.png", "g2.png"], "http screenshot dropped")
    }

    func testSourceWithNoUsableAppIsAnError() throws {
        XCTAssertThrowsError(try CatalogFixtures.parse("altstore-noapps.json")) { error in
            guard case CatalogFailure.noUsableApps(let warnings) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(warnings.count, 2)
        }
    }

    func testPlayCoverArray() throws {
        let source = try CatalogFixtures.parse("playcover-array.json")
        XCTAssertEqual(source.format, .playCover)
        XCTAssertEqual(source.name, "example.com", "no name in the file, so the host labels it")
        XCTAssertEqual(source.apps.map(\.bundleID), ["com.example.game", "com.example.other"])
        let game = try XCTUnwrap(source.apps.first?.latest)
        XCTAssertEqual(game.version, "1.2.3")
        XCTAssertEqual(game.sha256, "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
        let other = try XCTUnwrap(source.apps.last?.latest)
        XCTAssertNil(other.sha256, "short checksum is not a SHA-256")
        XCTAssertEqual(other.downloadURL.absoluteString, "https://example.com/repo/files/other.ipa")
        let text = source.warnings.joined(separator: "\n")
        XCTAssertTrue(text.contains("checksum"), text)
        XCTAssertTrue(text.contains("com.example.nolink"), text)
        XCTAssertTrue(text.contains("No Bundle"), text)
    }

    func testPlayCoverWrapper() throws {
        let source = try CatalogFixtures.parse("playcover-wrapper.json")
        XCTAssertEqual(source.format, .playCover)
        XCTAssertEqual(source.name, "PC Source")
        XCTAssertEqual(source.identifier, "pc.source.id")
        XCTAssertEqual(source.apps.first?.bundleID, "com.example.wrapped")
        XCTAssertTrue(source.warnings.isEmpty, "\(source.warnings)")
    }

    func testUnknownAndInvalidDocuments() throws {
        XCTAssertThrowsError(try CatalogFixtures.parse("unknown-format.json")) {
            XCTAssertEqual($0 as? CatalogFailure, .unrecognizedFormat)
        }
        XCTAssertThrowsError(try SourceParser.parse(data: Data("<html>".utf8), from: CatalogFixtures.sourceURL)) {
            XCTAssertEqual($0 as? CatalogFailure, .notJSON)
        }
    }

    func testUTF8ByteOrderMarkIsAccepted() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(try CatalogFixtures.data("altstore-legacy.json"))
        XCTAssertEqual(try SourceParser.parse(data: data, from: CatalogFixtures.sourceURL).apps.count, 1)
    }

    func testRelativeURLsResolveAgainstAFileSourceAndFileURLsAreAllowedThere() throws {
        let json = #"{"apps":[{"name":"L","bundleIdentifier":"l","versions":[{"version":"1","downloadURL":"l.ipa"}]}]}"#
        let local = URL(fileURLWithPath: "/tmp/repo/source.json")
        let app = try XCTUnwrap(SourceParser.parse(data: Data(json.utf8), from: local).apps.first)
        XCTAssertEqual(app.latest?.downloadURL.path, "/tmp/repo/l.ipa")
    }

    func testRemoteSourceCannotPointAtLocalFiles() {
        let json = #"{"apps":[{"name":"L","bundleIdentifier":"l","versions":[{"version":"1","downloadURL":"file:///etc/passwd"}]}]}"#
        XCTAssertThrowsError(try SourceParser.parse(data: Data(json.utf8), from: CatalogFixtures.sourceURL)) {
            guard case CatalogFailure.noUsableApps = $0 else { return XCTFail("\($0)") }
        }
    }
}

final class CatalogURLPolicyTests: XCTestCase {
    private func allowed(_ text: String, file: Bool = false) -> Bool {
        URL(string: text).map { URLPolicy.isAllowed($0, allowFile: file) } ?? false
    }

    func testHTTPSIsAllowedAndPlainHTTPIsNot() {
        XCTAssertTrue(allowed("https://example.com/a.ipa"))
        XCTAssertFalse(allowed("http://example.com/a.ipa"))
        XCTAssertFalse(allowed("ftp://example.com/a.ipa"))
        XCTAssertFalse(allowed("data:text/plain,hi"))
    }

    func testHTTPToLoopbackIsAllowed() {
        XCTAssertTrue(allowed("http://localhost:8080/a"))
        XCTAssertTrue(allowed("http://127.0.0.1/a"))
        XCTAssertTrue(allowed("http://[::1]:9/a"))
        XCTAssertFalse(allowed("http://127.0.0.1.example.com/a"))
        XCTAssertFalse(allowed("http://localhost.example.com/a"))
    }

    func testFileURLsNeedTheFlag() {
        XCTAssertFalse(allowed("file:///tmp/a.ipa"))
        XCTAssertTrue(allowed("file:///tmp/a.ipa", file: true))
    }

    func testResolveRelativeAndRejectBlank() {
        let base = URL(string: "https://example.com/a/b.json")
        XCTAssertEqual(URLPolicy.resolve("c.png", against: base, allowFile: false)?.absoluteString, "https://example.com/a/c.png")
        XCTAssertEqual(URLPolicy.resolve("/c.png", against: base, allowFile: false)?.absoluteString, "https://example.com/c.png")
        XCTAssertNil(URLPolicy.resolve("   ", against: base, allowFile: false))
    }
}
