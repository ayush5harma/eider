import Foundation
import XCTest
@testable import EiderKit

@MainActor
final class BrowsePublishingTests: XCTestCase {
    private func model(
        catalog: [SourcedApp] = BrowseFixtures.varied(), installed: [InstalledApp] = []
    ) async throws -> (AppModel, StubBackend) {
        let backend = StubBackend()
        backend.setCatalog(catalog)
        backend.setInstalled(installed)
        let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: backend)
        model.browseDebounce = .zero
        await model.reload()
        await model.settleBrowse()
        return (model, backend)
    }

    func testResultsAreEmptyUntilTheFirstReloadAndSortedAfterIt() async throws {
        let backend = StubBackend()
        backend.setCatalog(BrowseFixtures.varied())
        let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: backend)
        XCTAssertTrue(model.browseResults.isEmpty)
        await model.reload()
        await model.settleBrowse()
        XCTAssertEqual(model.browseResults.map(\.id), OldBrowseFilter.apply(BrowseFilter(), to: BrowseFixtures.varied()).map(\.id))
    }

    func testTypedQueryAndSourceChoicePublishWhatTheOldImplementationReturned() async throws {
        let (model, _) = try await model()
        for text in ["cafe", "beta works", "same", "nothing like this", ""] {
            model.filter.text = text
            await model.settleBrowse()
            XCTAssertEqual(model.browseResults.map(\.id), OldBrowseFilter.apply(model.filter, to: model.catalog).map(\.id), text)
        }
        model.filter.source = BrowseFixtures.sourceB
        await model.settleBrowse()
        XCTAssertEqual(model.browseResults.map(\.id), OldBrowseFilter.apply(model.filter, to: model.catalog).map(\.id))
    }

    func testClearingTheQueryRestoresTheFullListAtOnceWithoutWaitingOrFiltering() async throws {
        let (model, _) = try await model()
        model.filter.text = "cafe"
        await model.settleBrowse()
        XCTAssertEqual(model.browseResults.count, 2)

        model.browseDebounce = .seconds(60)
        model.filter.text = ""
        XCTAssertEqual(model.browseResults.count, model.catalog.count, "published synchronously, not after the debounce")
        XCTAssertNil(model.filterTask)
    }

    func testTypingBurstsAreDebouncedAndOnlyTheLastQueryIsPublished() async throws {
        let (model, _) = try await model()
        model.browseDebounce = .milliseconds(80)
        let before = model.browseResults
        model.filter.text = "z"
        model.filter.text = "ze"
        model.filter.text = "zet"
        model.filter.text = "zeta"
        XCTAssertEqual(model.browseResults.map(\.id), before.map(\.id), "nothing published while the debounce runs")
        await model.settleBrowse()
        XCTAssertEqual(model.browseResults.map(\.app.bundleID), ["com.words", "com.zeta.app"])
    }

    func testAStaleQueryNeverOverwritesANewerOne() async throws {
        let (model, _) = try await model()
        model.browseDebounce = .milliseconds(30)
        model.filter.text = "alpha"
        try await Task.sleep(for: .milliseconds(60))
        model.filter.text = "zeta"
        await model.settleBrowse()
        XCTAssertTrue(model.browseResults.allSatisfy { $0.app.name.lowercased().contains("zeta") })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.browseResults.allSatisfy { $0.app.name.lowercased().contains("zeta") })
    }

    func testReloadingTheSameCatalogKeepsTheIndexAndPublishesNothingNew() async throws {
        let (model, _) = try await model()
        let generation = model.indexGeneration
        let index = model.browseIndex
        await model.reload()
        await model.settleBrowse()
        XCTAssertEqual(model.indexGeneration, generation, "no rebuild for an unchanged catalog")
        XCTAssertTrue(model.browseIndex === index)
    }

    func testAChangedCatalogRebuildsTheIndexAndRefiltersWithTheCurrentQuery() async throws {
        let (model, backend) = try await model()
        model.filter.text = "alpha"
        await model.settleBrowse()
        XCTAssertEqual(model.browseResults.count, 3)

        let source = BrowseFixtures.source(BrowseFixtures.sourceA, name: "A")
        backend.setCatalog(BrowseFixtures.varied() + [BrowseFixtures.entry(source, "com.new", "Alphabet Soup")])
        await model.reload()
        await model.settleBrowse()
        XCTAssertEqual(model.browseResults.count, 4)
        XCTAssertEqual(model.catalog.count, 21)
    }

    func testAFilterChangedWhileTheIndexRebuildsIsAppliedWhenItLands() async throws {
        let (model, backend) = try await model()
        let source = BrowseFixtures.source(BrowseFixtures.sourceA, name: "A")
        backend.setCatalog(BrowseFixtures.varied() + [BrowseFixtures.entry(source, "com.new", "Alphabet Soup")])
        await model.reload()
        model.filter.text = "soup"
        await model.settleBrowse()
        XCTAssertEqual(model.browseResults.map(\.app.bundleID), ["com.new"])
    }

    func testSelectedEntryFindsAnAppTheFilterHidesAndNothingForAnUnknownID() async throws {
        let (model, _) = try await model()
        let zeta = try XCTUnwrap(model.catalog.first { $0.app.bundleID == "com.zeta.app" })
        model.selectedAppID = zeta.id
        model.filter.text = "cafe"
        await model.settleBrowse()
        XCTAssertFalse(model.browseResults.contains { $0.id == zeta.id })
        XCTAssertEqual(model.selectedEntry?.id, zeta.id)
        model.selectedAppID = "https://a.example.com/source.json|nope"
        XCTAssertNil(model.selectedEntry)
        model.selectedAppID = nil
        XCTAssertNil(model.selectedEntry)
    }

    func testStatusIsIndexedByBundleIDAndFollowsTheInstalledList() async throws {
        let source = BrowseFixtures.source(BrowseFixtures.sourceA, name: "A")
        let one = BrowseFixtures.entry(source, "com.one", "One")
        let two = BrowseFixtures.entry(source, "com.two", "Two")
        let (model, backend) = try await model(
            catalog: [one, two], installed: [AppModelFixtures.installedApp("com.one", name: "One", version: "1.0")])
        XCTAssertEqual(model.status(of: one.app), .installed(version: "1.0"))
        XCTAssertEqual(model.status(of: two.app), .notInstalled)

        backend.setInstalled([AppModelFixtures.installedApp("com.two", name: "Two", version: "2.0")])
        await model.reload()
        XCTAssertEqual(model.status(of: one.app), .notInstalled)
        XCTAssertEqual(model.status(of: two.app), .installed(version: "2.0"))
    }
}
