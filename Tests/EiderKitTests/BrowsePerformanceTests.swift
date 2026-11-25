import Foundation
import XCTest
@testable import EiderKit

/// A source of 17,430 apps made the window slow: every read of the browse
/// results sorted the catalog on the main actor, and every row selection scanned
/// it. Measured on that catalog before the index (debug build): one read of the
/// results 273-295 ms (two per body), one selectedEntry 14 ms. These tests hold
/// the bounds with a wide margin so a loaded machine does not flake them; the
/// numbers go to the log with the prefix `BROWSE-PERF`.
@MainActor
final class BrowsePerformanceTests: XCTestCase {
    private static let appCount = 17_430
    private static let reads = 1_000

    private static let nouns = ["Photo", "Tele", "Cloud", "Game", "Notes", "Music", "Radio", "Map", "Cam", "Pay", "Chat", "Fit", "Draw", "Mail", "Clock"]
    private static let adjectives = ["Super", "Mini", "Pro", "Lite", "Ultra", "Smart", "Café", "Zen", "Neo", "Retro"]
    private static let developers = ["Acme", "Beta Works", "Müller", "Studio Nine", nil, "Dev Co", "Ünal"]

    /// Deterministic, with repeated names, accents, and missing fields.
    private static func syntheticCatalog(count: Int) -> [SourcedApp] {
        let source = BrowseFixtures.source(BrowseFixtures.sourceA, name: "Big")
        return (0..<count).map { i in
            let name = "\(adjectives[i % adjectives.count]) \(nouns[(i / 7) % nouns.count]) \(i % 997)"
            return BrowseFixtures.entry(
                source, "com.example.app\(i)", name,
                developer: developers[i % developers.count], subtitle: i % 3 == 0 ? "Subtitle \(i % 50)" : nil)
        }
    }

    private func catalogUnderTest() throws -> [SourcedApp] {
        // EIDER_BROWSE_PERF_FILE=/path/to/repo.json runs it against a real source
        // as well; parsing one that size takes seconds, so it is opt-in.
        if let path = ProcessInfo.processInfo.environment["EIDER_BROWSE_PERF_FILE"] {
            let source = try SourceParser.parse(data: Data(contentsOf: URL(fileURLWithPath: path)), from: BrowseFixtures.sourceA)
            return source.apps.map { SourcedApp(source: source, app: $0) }
        }
        return Self.syntheticCatalog(count: Self.appCount)
    }

    private func milliseconds(_ block: () async -> Void) async -> Double {
        let start = ContinuousClock.now
        await block()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    func testTypedQueryIsPublishedWellUnderAHundredMillisecondsAndReadsDoNoCatalogWork() async throws {
        let catalog = try catalogUnderTest()
        let installed = AppModelFixtures.installedApp(catalog[catalog.count - 1].app.bundleID, name: "x", version: "1")
        let backend = StubBackend()
        backend.setCatalog(catalog)
        backend.setInstalled([installed])
        let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: backend)
        model.browseDebounce = .zero

        let build = await milliseconds {
            await model.reload()
            await model.settleBrowse()
        }
        XCTAssertEqual(model.browseResults.count, catalog.count)
        print("BROWSE-PERF apps \(catalog.count): reload + index build off the main actor \(build) ms")

        // The window may have shown the whole list; the person now types.
        let publish = await milliseconds {
            model.filter.text = "tele"
            await model.settleBrowse()
        }
        XCTAssertFalse(model.browseResults.isEmpty)
        XCTAssertLessThan(model.browseResults.count, catalog.count)
        print("BROWSE-PERF typed query published (no debounce) \(publish) ms, \(model.browseResults.count) results")
        XCTAssertLessThan(publish, 100, "filtering and publishing a typed query")

        let second = await milliseconds {
            model.filter.text = "tele pro"
            await model.settleBrowse()
        }
        print("BROWSE-PERF two-word query published \(second) ms")
        XCTAssertLessThan(second, 100)

        let target = try XCTUnwrap(model.catalog.last)
        model.selectedAppID = target.id
        let reads = Self.reads
        let resultReads = await milliseconds { for _ in 0..<reads { _ = model.browseResults.count } }
        let selectedReads = await milliseconds { for _ in 0..<reads { _ = model.selectedEntry } }
        let statusReads = await milliseconds { for _ in 0..<reads { _ = model.status(of: target.app) } }
        print("BROWSE-PERF \(reads) reads: browseResults \(resultReads) ms, selectedEntry \(selectedReads) ms, status(of:) \(statusReads) ms")
        XCTAssertEqual(model.selectedEntry?.id, target.id)
        XCTAssertEqual(model.status(of: target.app), .installed(version: "1"))
        // The old selectedEntry alone took 14 ms a read here (14 s for 1,000).
        XCTAssertLessThan(resultReads, 250)
        XCTAssertLessThan(selectedReads, 250)
        XCTAssertLessThan(statusReads, 250)

        let clear = await milliseconds { model.filter.text = "" }
        XCTAssertEqual(model.browseResults.count, catalog.count)
        print("BROWSE-PERF clearing the query (no sort) \(clear) ms")
        XCTAssertLessThan(clear, 50)
    }

    func testReadsDoNotGrowWithTheCatalog() async throws {
        func cost(of count: Int) async throws -> Double {
            let catalog = Self.syntheticCatalog(count: count)
            let backend = StubBackend()
            backend.setCatalog(catalog)
            let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: backend)
            await model.reload()
            await model.settleBrowse()
            let target = try XCTUnwrap(model.catalog.last)
            model.selectedAppID = target.id
            return await milliseconds {
                for _ in 0..<Self.reads {
                    _ = model.browseResults.count
                    _ = model.selectedEntry
                    _ = model.status(of: target.app)
                }
            }
        }
        let small = try await cost(of: 1_000)
        let large = try await cost(of: Self.appCount)
        print("BROWSE-PERF 3 x \(Self.reads) reads: 1,000 apps \(small) ms, \(Self.appCount) apps \(large) ms")
        // 17x the apps; allow a generous 10x for noise rather than 17x for linear work.
        XCTAssertLessThan(large, max(small * 10, 50))
    }
}
