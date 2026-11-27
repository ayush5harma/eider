import Foundation
import XCTest
@testable import EiderKit

final class SourceListIOTests: XCTestCase {
    private func parse(_ text: String) throws -> ParsedSourceList {
        try SourceListIO.parse(Data(text.utf8))
    }

    private func urls(_ list: ParsedSourceList) -> [String] { list.urls.map(\.absoluteString) }

    func testEiderJSONRoundTripsThroughExport() throws {
        let a = try CatalogFixtures.parse("altstore-standard.json", from: URL(string: "https://a.example.com/s.json")!)
        let b = try CatalogFixtures.parse("altstore-standard.json", from: URL(string: "https://b.example.com/s.json")!)
        let data = try SourceListIO.exportJSON([a, b], now: Date.utc(2026, 11, 28))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"format\" : \"eider-sources\""))
        XCTAssertTrue(text.contains("2026-11-28T00:00:00Z"))
        XCTAssertEqual(urls(try SourceListIO.parse(data)), ["https://a.example.com/s.json", "https://b.example.com/s.json"])
    }

    func testTextExportIsOneAddressPerLine() throws {
        let a = try CatalogFixtures.parse("altstore-standard.json", from: URL(string: "https://a.example.com/s.json")!)
        XCTAssertEqual(SourceListIO.exportText([a]), "https://a.example.com/s.json\n")
        XCTAssertEqual(SourceListIO.exportText([]), "")
    }

    func testJSONArrayOfStringsAndOfObjects() throws {
        XCTAssertEqual(
            urls(try parse(#"["https://a.example.com/1.json", "https://a.example.com/2.json"]"#)),
            ["https://a.example.com/1.json", "https://a.example.com/2.json"])
        let objects = try parse(#"[{"url": "https://a.example.com/1.json", "name": "One"}, {"name": "no url"}]"#)
        XCTAssertEqual(urls(objects), ["https://a.example.com/1.json"])
        XCTAssertEqual(objects.rejected.count, 1)
    }

    func testPlainTextSkipsBlankLinesAndComments() throws {
        let list = try parse("# my sources\n\n  https://a.example.com/1.json  \r\n#https://a.example.com/skipped.json\nhttps://a.example.com/2.json\n")
        XCTAssertEqual(urls(list), ["https://a.example.com/1.json", "https://a.example.com/2.json"])
        XCTAssertTrue(list.rejected.isEmpty)
    }

    func testDeepLinksAreUnwrappedAndInstallLinksRejected() throws {
        let list = try parse("""
            eider://source/https://a.example.com/1.json
            eider://install/https://a.example.com/app.ipa
            eider://source/http://127.0.0.1/x.json
            """)
        XCTAssertEqual(urls(list), ["https://a.example.com/1.json"])
        XCTAssertEqual(list.rejected.count, 2)
        XCTAssertTrue(list.rejected[0].reason.contains("install link"))
    }

    func testRepeatsInTheFileAreCollapsed() throws {
        let list = try parse("https://a.example.com/1.json\nhttps://a.example.com/1.json\n")
        XCTAssertEqual(list.urls.count, 1)
        XCTAssertEqual(list.repeated.count, 1)
    }

    func testPolicyRejectionsCarryTheirReason() throws {
        let list = try parse("""
            http://example.com/s.json
            file:///etc/passwd
            http://localhost:8080/s.json
            ftp://example.com/s.json
            not a url
            https://ok.example.com/s.json
            """)
        XCTAssertEqual(urls(list), ["https://ok.example.com/s.json"])
        XCTAssertEqual(list.rejected.count, 5)
        XCTAssertEqual(list.rejected[0].reason, "only https addresses are allowed")
        XCTAssertTrue(list.rejected[1].reason.contains("file on this Mac"))
        XCTAssertTrue(list.rejected[2].reason.contains("address on this Mac"))
    }

    func testCapsOnSizeAndCount() throws {
        XCTAssertThrowsError(try SourceListIO.parse(Data(count: SourceListIO.maxBytes + 1))) {
            XCTAssertEqual($0 as? SourceListError, .tooLarge(limit: SourceListIO.maxBytes))
        }
        let many = (0...SourceListIO.maxEntries).map { "https://a.example.com/\($0).json" }.joined(separator: "\n")
        XCTAssertThrowsError(try parse(many)) {
            XCTAssertEqual($0 as? SourceListError, .tooManyEntries(limit: SourceListIO.maxEntries))
        }
        let exactly = (1...SourceListIO.maxEntries).map { "https://a.example.com/\($0).json" }.joined(separator: "\n")
        XCTAssertEqual(try parse(exactly).urls.count, SourceListIO.maxEntries)
    }

    func testForeignJSONAndEmptyInputAreErrors() {
        XCTAssertThrowsError(try parse(#"{"format": "other", "sources": []}"#))
        XCTAssertThrowsError(try parse(#"{"format": "eider-sources", "version": 2, "sources": []}"#))
        XCTAssertThrowsError(try parse("# nothing here\n\n")) {
            XCTAssertEqual($0 as? SourceListError, .noEntries)
        }
    }

    func testImportAddsNewOnesSkipsKnownAndKeepsGoingAfterAFailure() async throws {
        let template = try CatalogFixtures.parse("altstore-standard.json")
        let list = """
            https://known.example.com/s.json
            https://good.example.com/s.json
            https://bad.example.com/s.json
            http://nope.example.com/s.json
            """
        let result = try await SourceListIO.importList(
            Data(list.utf8), existing: [URL(string: "https://known.example.com/s.json")!],
            add: { url in
                if url.host == "bad.example.com" { throw CatalogFailure.fetchFailed("boom") }
                return template
            })
        XCTAssertEqual(result.added, ["https://good.example.com/s.json"])
        XCTAssertEqual(result.alreadyPresent, ["https://known.example.com/s.json"])
        XCTAssertEqual(result.rejected.count, 1)
        XCTAssertEqual(result.failed.map(\.url), ["https://bad.example.com/s.json"])
        XCTAssertEqual(result.summary, "Added 1 \u{00B7} 1 already added \u{00B7} 1 rejected \u{00B7} 1 failed")
    }

    func testImportNeverRunsMoreThanFourFetchesAtOnce() async throws {
        let template = try CatalogFixtures.parse("altstore-standard.json")
        let counter = ConcurrencyCounter()
        let list = (1...12).map { "https://a.example.com/\($0).json" }.joined(separator: "\n")
        let result = try await SourceListIO.importList(Data(list.utf8), existing: [], add: { _ in
            await counter.enter()
            try await Task.sleep(nanoseconds: 20_000_000)
            await counter.leave()
            return template
        })
        XCTAssertEqual(result.added.count, 12)
        let peak = await counter.peak
        XCTAssertEqual(peak, SourceListIO.maxConcurrentFetches)
    }
}

private actor ConcurrencyCounter {
    private var running = 0
    private(set) var peak = 0

    func enter() {
        running += 1
        peak = max(peak, running)
    }

    func leave() { running -= 1 }
}
