import Foundation
import XCTest
@testable import EiderKit

@MainActor
final class AppModelSourcesLinksTests: XCTestCase {
    private typealias F = AppModelFixtures

    private func twoSources() throws -> (AppModel, FakeFetch) {
        let fake = FakeFetch()
        fake.set(F.sourceA, json: F.altStore(name: "A", apps: [("com.a", "App A", "Dev", ["1"])]))
        fake.set(F.sourceB, json: F.altStore(name: "B", apps: [("com.b", "App B", "Dev", ["1"]), ("com.c", "App C", "Dev", ["1"])]))
        return (try F.liveModel(fetch: fake).model, fake)
    }

    // MARK: Sources

    func testAddingFromTheTextFieldFetchesOnceSelectsTheSourceAndClearsTheField() async throws {
        let (model, fake) = try twoSources()
        model.newSourceText = "  \(F.sourceA.absoluteString)  "
        await model.addSourceFromText()

        XCTAssertEqual(model.sources.map(\.name), ["A"])
        XCTAssertEqual(model.sources.first?.apps.count, 1)
        XCTAssertEqual(model.selectedSource?.url, F.sourceA)
        XCTAssertEqual(model.newSourceText, "")
        XCTAssertEqual(fake.count(F.sourceA), 1)
        XCTAssertNil(model.errorMessage)
    }

    func testABadAddressOrAFailingFetchShowsAnErrorWithItsCodeAndAddsNothing() async throws {
        let (model, _) = try twoSources()
        model.newSourceText = "not a url"
        await model.addSourceFromText()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.sources.isEmpty)

        model.errorMessage = nil
        model.newSourceText = "https://nowhere.example.com/source.json"
        await model.addSourceFromText()
        XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("catalog."), "the stable code is shown")
        XCTAssertEqual(model.newSourceText, "https://nowhere.example.com/source.json", "the text stays for a correction")
        XCTAssertTrue(model.sources.isEmpty)
    }

    func testRemovingASourceDropsItsAppsAndAnyFilterOnIt() async throws {
        let (model, _) = try twoSources()
        await model.addSource(F.sourceA)
        await model.addSource(F.sourceB)
        XCTAssertEqual(model.catalog.count, 3)
        model.filter.source = F.sourceB

        await model.removeSource(try XCTUnwrap(model.sources.first { $0.url == F.sourceB }))
        XCTAssertEqual(model.sources.map(\.url), [F.sourceA])
        XCTAssertEqual(model.catalog.map(\.app.bundleID), ["com.a"])
        XCTAssertNil(model.filter.source)
    }

    func testRefreshAllFetchesEverySourceOnItsOwnAndRecordsWhichOneFailed() async throws {
        let (model, fake) = try twoSources()
        await model.addSource(F.sourceA)
        await model.addSource(F.sourceB)
        fake.set(F.sourceA, json: F.altStore(name: "A", apps: [("com.a", "App A", "Dev", ["2", "1"]), ("com.a2", "More", "Dev", ["1"])]))
        fake.set(F.sourceB, error: CatalogFailure.fetchFailed("the server is down"))

        await model.refreshAllSources()
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.sources.first { $0.url == F.sourceA }?.apps.count, 2, "the good source refreshed")
        XCTAssertEqual(model.sources.first { $0.url == F.sourceB }?.apps.count, 2, "the failed one kept its saved copy")
        XCTAssertEqual(Set(model.refreshFailures.keys), [F.sourceB])
        XCTAssertTrue(try XCTUnwrap(model.refreshFailures[F.sourceB]).contains("the server is down"))
    }

    func testReloadingNeverTouchesTheNetwork() async throws {
        let (model, fake) = try twoSources()
        await model.addSource(F.sourceA)
        let before = fake.count(F.sourceA)
        await model.reload()
        await model.reload()
        XCTAssertEqual(fake.count(F.sourceA), before)
    }

    // MARK: Deep links

    func testASourceLinkOnlyAsksAndShowsTheFullAddressNothingIsAddedUntilConfirmed() async throws {
        let (model, fake) = try twoSources()
        let link = URL(string: "eider://source/\(F.sourceA.absoluteString)")!
        model.handleOpened([link])

        XCTAssertEqual(model.pendingLink, .addSource(F.sourceA))
        XCTAssertEqual(model.pendingLink?.url.absoluteString, F.sourceA.absoluteString, "the whole address is what the sheet shows")
        XCTAssertEqual(fake.count(F.sourceA), 0, "no request before the person agrees")
        XCTAssertTrue(model.sources.isEmpty)

        model.dismissPendingLink()
        XCTAssertNil(model.pendingLink)
        XCTAssertEqual(fake.count(F.sourceA), 0)
        XCTAssertTrue(model.sources.isEmpty)

        model.handleOpened([link])
        await model.confirmPendingLink()
        XCTAssertEqual(model.sources.map(\.url), [F.sourceA])
        XCTAssertEqual(model.selection, .sources)
    }

    func testAnInstallLinkStillNeedsTheOptionsSheetAfterConfirmation() async throws {
        let (model, _) = try twoSources()
        let target = "https://cdn.example.com/get/app.ipa?token=abc#frag"
        model.handleDeepLink(URL(string: "eider://install/\(target)")!)
        XCTAssertEqual(model.pendingLink, .install(URL(string: target)!))
        XCTAssertNil(model.pendingInstall)
        XCTAssertTrue(model.activity.items.isEmpty)

        await model.confirmPendingLink()
        XCTAssertNil(model.pendingLink)
        XCTAssertEqual(model.pendingInstall?.request, .url(URL(string: target)!))
        XCTAssertTrue(model.activity.items.isEmpty, "nothing runs until the options sheet is confirmed")
    }

    func testUnusableLinksAreRefusedWithTheAddressShown() async throws {
        let (model, _) = try twoSources()
        for bad in ["eider://source/file:///etc/passwd", "eider://install/ftp://example.com/a.ipa", "eider://other/https://x.example.com/", "eider://source/http://evil.example.com/s.json"] {
            model.errorMessage = nil
            model.handleDeepLink(URL(string: bad)!)
            XCTAssertNil(model.pendingLink, bad)
            XCTAssertTrue(try XCTUnwrap(model.errorMessage, bad).contains(bad), bad)
        }
    }

    // MARK: Settings and the update check

    func testTheDefaultInstallLocationIsApplicationsAndPersistsInSettingsJSONUnderTheHome() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        let first = AppModel(paths: paths, backend: StubBackend())
        XCTAssertEqual(first.settings.defaultInstallLocation.path, "/Applications")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppSettings.file(in: paths).path), "defaults are not written until changed")

        first.setDefaultInstallLocation(URL(fileURLWithPath: "/tmp/My Apps", isDirectory: true))
        XCTAssertEqual(AppSettings.file(in: paths).deletingLastPathComponent().path, paths.home.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.home.appendingPathComponent("settings.json").path))

        let second = AppModel(paths: paths, backend: StubBackend())
        XCTAssertEqual(second.settings.defaultInstallLocation.path, "/tmp/My Apps")
    }

    func testACorruptSettingsFileFallsBackToTheDefaults() throws {
        let paths = try CatalogFixtures.temporaryHome()
        try Data("{ not json".utf8).write(to: AppSettings.file(in: paths))
        XCTAssertEqual(AppSettings.load(from: paths), AppSettings())
    }

    func testTheUpdateCheckAsksOnceAndReportsNewerOrCurrent() async throws {
        let calls = FakeFetch()
        func check(_ json: String, current: String = "0.1.0") async -> ReleaseCheckState {
            calls.set(ReleaseCheck.latestReleaseURL, json: json)
            return await ReleaseCheck(fetch: calls.fetch, current: current).run()
        }
        let newer = await check(#"{"tag_name":"v0.2.0","html_url":"https://github.com/ayush5harma/eider/releases/tag/v0.2.0"}"#)
        XCTAssertEqual(newer, .newer(version: "0.2.0", url: URL(string: "https://github.com/ayush5harma/eider/releases/tag/v0.2.0")!))
        let same = await check(#"{"tag_name":"v0.1.0","html_url":"https://github.com/ayush5harma/eider/releases/tag/v0.1.0"}"#)
        XCTAssertEqual(same, .upToDate(current: "0.1.0"))
        let elsewhere = await check(#"{"tag_name":"v9.0.0","html_url":"https://evil.example.com/x"}"#)
        guard case .failed = elsewhere else { return XCTFail("a link off GitHub must be refused, got \(elsewhere)") }
        let garbage = await check("<html>")
        guard case .failed = garbage else { return XCTFail("expected a failure, got \(garbage)") }
        XCTAssertEqual(calls.count(ReleaseCheck.latestReleaseURL), 4, "one request per check")
    }

    func testChooseCheckForUpdatesSetsTheStateAndNoCheckHappensAtStartup() async throws {
        let calls = FakeFetch()
        calls.set(ReleaseCheck.latestReleaseURL, json: #"{"tag_name":"v0.1.0","html_url":"https://github.com/ayush5harma/eider/releases/tag/v0.1.0"}"#)
        let (model, _) = try F.liveModel(fetch: FakeFetch(), release: ReleaseCheck(fetch: calls.fetch))
        await model.reload()
        XCTAssertEqual(calls.count(ReleaseCheck.latestReleaseURL), 0)
        XCTAssertEqual(model.releaseCheck, .idle)

        await model.checkForUpdates()
        XCTAssertEqual(model.releaseCheck, .upToDate(current: EiderVersion.current))
        XCTAssertEqual(calls.count(ReleaseCheck.latestReleaseURL), 1)
    }
}
