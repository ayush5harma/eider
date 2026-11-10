import CryptoKit
import Foundation
import XCTest
@testable import EiderKit

/// What the installer was asked to do, and the events the caller saw.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _installs: [(file: URL, options: InstallOptions)] = []
    private var _events: [OperationEvent] = []

    var installs: [(file: URL, options: InstallOptions)] { lock.withLock { _installs } }
    var events: [OperationEvent] { lock.withLock { _events } }
    func record(_ file: URL, _ options: InstallOptions) { lock.withLock { _installs.append((file, options)) } }
    func record(_ event: OperationEvent) { lock.withLock { _events.append(event) } }
}

final class OperationsTests: XCTestCase {
    private let sourceURL = URL(string: "https://src.example.com/s.json")!
    private let body = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 13) })
    private var paths: EiderPaths!
    private var recorder: Recorder!
    private var fake: FakeFetch!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        paths = try CatalogFixtures.temporaryHome()
        recorder = Recorder()
        fake = FakeFetch()
        StubURLProtocol.handler = { [body] _ in StubURLProtocol.Reply(chunks: [body]) }
    }

    override func tearDown() { StubURLProtocol.reset() }

    private var bodyHash: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }

    private func operations(installedName: String = "X") -> AppOperations {
        let library = LibraryStore(paths: paths)
        let recorder = self.recorder!
        let destination = paths.home.appendingPathComponent("apps", isDirectory: true)
        return AppOperations(
            sources: SourceStore(paths: paths, fetch: fake.fetch), library: library,
            downloads: DownloadManager(paths: paths, configuration: StubURLProtocol.configuration()),
            installIPA: { file, options, onEvent in
                recorder.record(file, options)
                onEvent(InstallEvent(step: .unpack, message: "unpack", fraction: 0))
                onEvent(InstallEvent(step: .done, message: "done", fraction: 1))
                let app = InstalledApp(
                    bundleID: "com.x", name: installedName, version: "2.0", build: "1",
                    path: destination.appendingPathComponent("X.app"), sourceURL: options.sourceURL,
                    ipaSHA256: options.ipaSHA256, options: options)
                try await library.record(app)
                return app
            },
            uninstaller: Uninstaller(store: library, containersDirectory: paths.home.appendingPathComponent("containers")))
    }

    private func source(_ versions: [(String, String)], id: String = "com.x") -> String {
        let list = versions.map { #"{"version":"\#($0.0)","buildVersion":"\#($0.1)","downloadURL":"https://cdn.example.com/\#(id)-\#($0.0).ipa"}"# }
        return #"{"name":"S","apps":[{"name":"X","bundleIdentifier":"\#(id)","versions":[\#(list.joined(separator: ","))]}]}"#
    }

    private func installedApp(version: String, build: String = "1", options: InstallOptions = InstallOptions()) -> InstalledApp {
        InstalledApp(
            bundleID: "com.x", name: "X", version: version, build: build,
            path: paths.home.appendingPathComponent("apps/X.app"), sourceURL: sourceURL, options: options)
    }

    // MARK: Install from a source

    func testInstallFromSourceDownloadsThenInstallsAndRecordsSourceAndHash() async throws {
        fake.set(sourceURL, json: source([("1.0", "1")]))
        let ops = operations()
        let added = try await ops.sources.add(url: sourceURL)
        let app = try XCTUnwrap(added.apps.first)
        let recorder = self.recorder!

        let installed = try await ops.install(app: app, from: added, options: InstallOptions(macIdiom: true)) { recorder.record($0) }

        XCTAssertEqual(recorder.installs.count, 1)
        let options = try XCTUnwrap(recorder.installs.first?.options)
        XCTAssertEqual(options.sourceURL, sourceURL)
        XCTAssertEqual(options.ipaSHA256, bodyHash)
        XCTAssertTrue(options.macIdiom, "the owner's options pass through")
        XCTAssertEqual(installed.ipaSHA256, bodyHash)
        let stored = try await ops.library.app(bundleID: "com.x")
        XCTAssertEqual(stored?.sourceURL, sourceURL)

        let events = recorder.events
        XCTAssertEqual(events.first?.phase, .download)
        XCTAssertTrue(events.contains { $0.phase == .download && $0.message.hasPrefix("Downloaded") })
        let installEvents = events.filter { $0.phase == .install }
        XCTAssertEqual(installEvents.map(\.step), ["unpack", "done"])
        XCTAssertEqual(installEvents.first?.fraction ?? 0, OperationEvent.downloadShare, accuracy: 0.0001, "install starts where the download ended")
        XCTAssertEqual(events.last?.fraction, 1)
        XCTAssertEqual(events.map(\.fraction), events.map(\.fraction).sorted(), "the bar never goes backwards")
    }

    func testRequestedVersionIsDownloaded() async throws {
        fake.set(sourceURL, json: source([("2.0", "2"), ("1.0", "1")]))
        let ops = operations()
        let added = try await ops.sources.add(url: sourceURL)
        let app = try XCTUnwrap(added.apps.first)

        _ = try await ops.install(app: app, version: try AppOperations.version("1.0", of: app), from: added)

        XCTAssertTrue(StubURLProtocol.requests.contains { $0.url?.lastPathComponent == "com.x-1.0.ipa" })
        XCTAssertThrowsError(try AppOperations.version("9.9", of: app)) {
            XCTAssertEqual(($0 as? OperationFailure)?.code, "operations.no_such_version")
            XCTAssertTrue(($0 as? OperationFailure)?.message.contains("2.0, 1.0") == true)
        }
    }

    func testDownloadFailureSurfacesWithItsOwnCodeAndNothingIsInstalled() async throws {
        StubURLProtocol.handler = { _ in StubURLProtocol.Reply(status: 404) }
        fake.set(sourceURL, json: source([("1.0", "1")]))
        let ops = operations()
        let added = try await ops.sources.add(url: sourceURL)

        do {
            _ = try await ops.install(app: try XCTUnwrap(added.apps.first), from: added)
            XCTFail("a 404 must fail")
        } catch let failure as OperationFailure {
            XCTAssertEqual(failure.code, "download.http_status")
        }
        XCTAssertTrue(recorder.installs.isEmpty)
    }

    // MARK: Direct and local

    func testDirectURLRefusesFileAndPlainHTTPToTheInternet() async {
        let ops = operations()
        for text in ["file:///tmp/a.ipa", "http://example.com/a.ipa", "ftp://example.com/a.ipa"] {
            do {
                _ = try await ops.install(ipaURL: URL(string: text)!)
                XCTFail("\(text) must be refused")
            } catch let failure as OperationFailure {
                XCTAssertEqual(failure.code, "operations.bad_url", text)
            } catch {
                XCTFail("\(error)")
            }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testDirectURLDownloadsAndRecordsTheAddressAsTheSource() async throws {
        let url = URL(string: "https://example.com/dl/App.ipa")!
        _ = try await operations().install(ipaURL: url)
        XCTAssertEqual(recorder.installs.first?.options.sourceURL, url)
        XCTAssertEqual(recorder.installs.first?.options.ipaSHA256, bodyHash)
    }

    func testLocalIPAIsHashedAndNotScaledByADownloadShare() async throws {
        let file = paths.home.appendingPathComponent("a.ipa")
        try paths.ensure()
        try body.write(to: file)
        let recorder = self.recorder!

        _ = try await operations().install(localIPA: file) { recorder.record($0) }

        XCTAssertEqual(recorder.installs.first?.options.ipaSHA256, bodyHash)
        XCTAssertNil(recorder.installs.first?.options.sourceURL)
        XCTAssertEqual(recorder.events.first?.fraction, 0)
        XCTAssertFalse(recorder.events.contains { $0.phase == .download })
    }

    func testMissingLocalIPAIsAnOperationFailure() async {
        do {
            _ = try await operations().install(localIPA: paths.home.appendingPathComponent("none.ipa"))
            XCTFail("a missing file must fail")
        } catch let failure as OperationFailure {
            XCTAssertEqual(failure.code, "operations.unreadable_file")
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Update

    func testUpdateReinstallsTheNewestVersionWithTheOptionsItWasInstalledWith() async throws {
        fake.set(sourceURL, json: source([("2.0", "1"), ("1.0", "1")]))
        let ops = operations()
        _ = try await ops.sources.add(url: sourceURL)
        var original = InstallOptions(destination: URL(fileURLWithPath: "/tmp/eider-apps"), macIdiom: true, keychainShim: false)
        original.resetData = true
        try await ops.library.record(installedApp(version: "1.0", options: original))

        let updated = try await ops.update(bundleID: "com.x")

        XCTAssertNotNil(updated)
        let options = try XCTUnwrap(recorder.installs.first?.options)
        XCTAssertEqual(options.destination.path, "/tmp/eider-apps")
        XCTAssertTrue(options.macIdiom)
        XCTAssertFalse(options.keychainShim)
        XCTAssertFalse(options.resetData, "an update never wipes the app's data")
        XCTAssertEqual(options.sourceURL, sourceURL)
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.url?.lastPathComponent == "com.x-2.0.ipa" })
    }

    func testUpdateNeverRunsForcedEvenIfTheLibraryFileSaysSo() async throws {
        fake.set(sourceURL, json: source([("2.0", "1"), ("1.0", "1")]))
        let ops = operations()
        _ = try await ops.sources.add(url: sourceURL)
        try await ops.library.record(installedApp(version: "1.0"))
        // A library.json from before force stopped being recorded, or edited by hand.
        let text = try String(contentsOf: paths.libraryFile).replacingOccurrences(of: #""force" : false"#, with: #""force" : true"#)
        try text.write(to: paths.libraryFile, atomically: true, encoding: .utf8)
        let stored = try await ops.library.app(bundleID: "com.x")
        XCTAssertEqual(stored?.options.force, true, "the fixture really carries force")

        _ = try await ops.update(bundleID: "com.x")

        XCTAssertEqual(recorder.installs.first?.options.force, false)
    }

    func testACatalogInstallExpectsTheCatalogIDAndADirectAddressDoesNot() async throws {
        fake.set(sourceURL, json: source([("1.0", "1")]))
        let ops = operations()
        let added = try await ops.sources.add(url: sourceURL)
        let app = try XCTUnwrap(added.apps.first)
        _ = try await ops.install(app: app, from: added)
        XCTAssertEqual(recorder.installs.last?.options.expectedBundleID, "com.x")

        _ = try await ops.install(ipaURL: URL(string: "https://cdn.example.com/direct.ipa")!)
        XCTAssertNil(recorder.installs.last?.options.expectedBundleID, "a direct address has a made-up id to compare against")
    }

    func testUpdateWhenCurrentReturnsNilAndInstallsNothing() async throws {
        fake.set(sourceURL, json: source([("1.0", "1")]))
        let ops = operations()
        _ = try await ops.sources.add(url: sourceURL)
        try await ops.library.record(installedApp(version: "1.0"))

        let result = try await ops.update(bundleID: "com.x")

        XCTAssertNil(result)
        XCTAssertTrue(recorder.installs.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testUpdateFailuresAreSpecific() async throws {
        let ops = operations()
        await assertCode("operations.not_installed") { _ = try await ops.update(bundleID: "com.x") }
        try await ops.library.record(installedApp(version: "1.0"))
        await assertCode("operations.not_in_catalog") { _ = try await ops.update(bundleID: "com.x") }
    }

    func testAvailableUpdatesMarksOnlyTheOutdatedApp() async throws {
        fake.set(sourceURL, json: source([("1.10", "1")]))
        let ops = operations()
        _ = try await ops.sources.add(url: sourceURL)
        try await ops.library.record(installedApp(version: "1.9"))

        let updates = try await ops.availableUpdates()

        XCTAssertEqual(updates.map(\.version.version), ["1.10"])
    }

    // MARK: Uninstall

    func testUninstallOfAnUnknownAppIsAnOperationFailure() async {
        await assertCode("uninstall.failed") { try await self.operations().uninstall(bundleID: "com.none") }
    }

    // MARK: Events and failures

    func testProgressEventsAreThinnedToWholePercents() {
        var mapper = DownloadEventMapper(label: "X 1")
        var emitted = 0
        for received in stride(from: Int64(0), through: 1000, by: 1) where mapper.map(.progress(received: received, expected: 1000)) != nil { emitted += 1 }
        XCTAssertLessThanOrEqual(emitted, 101)
        XCTAssertGreaterThan(emitted, 50)
    }

    func testEventEncodesForJSONOutput() throws {
        let event = OperationEvent(phase: .download, step: "download", message: "m", fraction: 2, bytesReceived: 5, bytesTotal: nil)
        XCTAssertEqual(event.fraction, 1)
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["phase"] as? String, "download")
        XCTAssertEqual(object["bytesReceived"] as? Int, 5)
        XCTAssertEqual(try JSONDecoder().decode(OperationEvent.self, from: data), event)
    }

    func testFailuresAreWrappedWithStableCodes() {
        XCTAssertEqual(OperationFailure.wrap(InstallFailure(.encrypted, "m")).code, "install.encrypted")
        XCTAssertEqual(OperationFailure.wrap(DownloadFailure.httpStatus(500)).code, "download.http_status")
        XCTAssertEqual(OperationFailure.wrap(CatalogFailure.notJSON).code, "catalog.not_json")
        XCTAssertEqual(OperationFailure.wrap(CocoaError(.fileNoSuchFile)).code, "operations.unexpected")
    }

    private func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let failure as OperationFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
