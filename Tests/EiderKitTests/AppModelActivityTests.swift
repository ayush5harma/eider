import Foundation
import XCTest
@testable import EiderKit

@MainActor
final class AppModelActivityTests: XCTestCase {
    private let ipa = URL(fileURLWithPath: "/tmp/Thing.ipa")

    private func installed() -> InstalledApp {
        AppModelFixtures.installedApp("com.thing", name: "Thing", version: "1.0")
    }

    func testEventsDriveTheRowFromDownloadBytesToInstallStepsToDone() async throws {
        let backend = StubBackend { _, _, emit in
            emit(OperationEvent(phase: .download, step: "download", message: "Downloading", fraction: 0.2, bytesReceived: 500, bytesTotal: 1000))
            emit(OperationEvent(phase: .install, step: "sign", message: "Signing", fraction: 0.7))
            return AppModelFixtures.installedApp("com.thing", name: "Thing", version: "1.0")
        }
        let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: backend)

        let id = model.activity.start(.localIPA(ipa))
        XCTAssertTrue(model.activity.hasRunning)
        await model.activity.waitUntilFinished(id)

        let item = try XCTUnwrap(model.activity.items.first)
        XCTAssertEqual(item.state, .succeeded)
        XCTAssertEqual(item.fraction, 1)
        XCTAssertEqual(item.phase, .install, "the last event seen was an install step")
        XCTAssertEqual(item.title, "Thing.ipa")
        XCTAssertFalse(model.activity.hasRunning)
    }

    func testProgressNeverMovesBackwardsEvenForAFastBurstOfEvents() async throws {
        let backend = StubBackend { _, _, emit in
            for step in 1...200 {
                emit(OperationEvent(phase: .download, step: "download", message: "d", fraction: Double(step) / 400, bytesReceived: Int64(step), bytesTotal: 200))
            }
            return nil
        }
        let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: backend)
        let id = model.activity.start(.localIPA(ipa))
        await model.activity.waitUntilFinished(id)
        XCTAssertEqual(model.activity.items.first?.bytesReceived, 200, "the last event wins, none applied late")
    }

    func testAFailureKeepsItsStableCodeAndSentenceAndRetryRunsTheSameRequestAgain() async throws {
        let backend = StubBackend { _, attempt, emit in
            emit(OperationEvent(phase: .download, step: "download", message: "Downloading", fraction: 0.1))
            if attempt == 1 { throw OperationFailure(code: "download.hash_changed", message: "The file changed since it was first downloaded.") }
            return AppModelFixtures.installedApp("com.thing", name: "Thing", version: "1.0")
        }
        let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: backend)
        let id = model.activity.start(.url(URL(string: "https://example.com/Thing.ipa")!))
        await model.activity.waitUntilFinished(id)

        var item = try XCTUnwrap(model.activity.items.first)
        XCTAssertEqual(item.state, .failed(code: "download.hash_changed", message: "The file changed since it was first downloaded."))
        XCTAssertTrue(item.canRetry)

        model.activity.retry(id)
        XCTAssertEqual(model.activity.items.first?.state, .running, "retry restarts the same row")
        await model.activity.waitUntilFinished(id)
        item = try XCTUnwrap(model.activity.items.first)
        XCTAssertEqual(item.state, .succeeded)
        XCTAssertEqual(model.activity.items.count, 1)
    }

    func testCancelStopsARunningOperationAndItCanBeRetried() async throws {
        let backend = StubBackend { _, attempt, _ in
            if attempt == 1 { try await Task.sleep(nanoseconds: 30_000_000_000) }
            return nil
        }
        let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: backend)
        let id = model.activity.start(.localIPA(ipa))
        try await Task.sleep(nanoseconds: 50_000_000)
        model.activity.cancel(id)
        await model.activity.waitUntilFinished(id)

        XCTAssertEqual(model.activity.items.first?.state, .cancelled)
        XCTAssertTrue(try XCTUnwrap(model.activity.items.first).canRetry)
        model.activity.retry(id)
        await model.activity.waitUntilFinished(id)
        XCTAssertEqual(model.activity.items.first?.state, .upToDate, "the stub's second attempt returns nil")
    }

    func testFinishingAnOperationReloadsTheLibrary() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        let backend = LiveBackend(paths: paths, fetch: FakeFetch().fetch)
        let model = AppModel(paths: paths, backend: backend)
        XCTAssertTrue(model.installed.isEmpty)
        try await LibraryStore(paths: paths).record(installed())

        // The operation fails (the file does not exist) but a finished
        // operation, failed or not, refreshes what the window shows.
        let id = model.activity.start(.localIPA(URL(fileURLWithPath: "/nonexistent/missing.ipa")))
        await model.activity.waitUntilFinished(id)
        for _ in 0..<100 where model.installed.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertEqual(model.installed.map(\.bundleID), ["com.thing"])
        guard case .failed(let code, _) = try XCTUnwrap(model.activity.items.first).state else { return XCTFail("expected a failure") }
        XCTAssertEqual(code, "operations.unreadable_file")
    }

    func testUpdateOfAnAppWithNothingNewerEndsUpToDateAndClearFinishedKeepsRunningRows() async throws {
        let backend = StubBackend { request, _, _ in
            if case .update = request { return nil }
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return nil
        }
        let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: backend)
        let slow = model.activity.start(.localIPA(ipa))
        let update = model.activity.start(.update(bundleID: "com.thing", name: "Thing"))
        await model.activity.waitUntilFinished(update)
        XCTAssertEqual(model.activity.items.first?.state, .upToDate)

        model.activity.clearFinished()
        XCTAssertEqual(model.activity.items.map(\.id), [slow])
        model.activity.cancel(slow)
        await model.activity.waitUntilFinished(slow)
    }

    func testConfirmingTheOptionsSheetStartsTheInstallWithThoseOptions() async throws {
        let backend = StubBackend { _, _, _ in nil }
        let paths = try CatalogFixtures.temporaryHome()
        let model = AppModel(paths: paths, backend: backend)
        model.setDefaultInstallLocation(URL(fileURLWithPath: "/tmp/Apps", isDirectory: true))

        XCTAssertTrue(model.handleFiles([ipa]))
        var pending = try XCTUnwrap(model.pendingInstall)
        XCTAssertEqual(pending.draft.destination.path, "/tmp/Apps", "the default location seeds the sheet")
        pending.draft.macIdiom = true
        pending.draft.keychainShim = false
        pending.draft.displayName = "  My Thing  "
        pending.draft.bundleID = " "
        pending.draft.resetData = true
        pending.draft.extraDylibs = [URL(fileURLWithPath: "/tmp/x.dylib")]
        model.pendingInstall = pending
        model.confirmPendingInstall()

        let options = try XCTUnwrap(model.activity.items.first?.options)
        XCTAssertTrue(options.macIdiom)
        XCTAssertFalse(options.keychainShim)
        XCTAssertEqual(options.displayName, "My Thing")
        XCTAssertNil(options.bundleID, "a blank field means no override")
        XCTAssertTrue(options.resetData)
        XCTAssertEqual(options.extraDylibs.map(\.path), ["/tmp/x.dylib"])
        XCTAssertEqual(options.destination.path, "/tmp/Apps")
        XCTAssertNil(model.pendingInstall)
        XCTAssertEqual(model.selection, .activity)
        await model.activity.waitUntilFinished(model.activity.items[0].id)
    }

    func testOnlyIPAFilesAreTakenFromADrop() throws {
        let model = AppModel(paths: try CatalogFixtures.temporaryHome(), backend: StubBackend())
        XCTAssertFalse(model.handleFiles([URL(fileURLWithPath: "/tmp/notes.txt")]))
        XCTAssertNil(model.pendingInstall)
        XCTAssertTrue(model.handleFiles([URL(fileURLWithPath: "/tmp/A.IPA")]))
        XCTAssertEqual(model.pendingInstall?.request, .localIPA(URL(fileURLWithPath: "/tmp/A.IPA")))
    }
}
