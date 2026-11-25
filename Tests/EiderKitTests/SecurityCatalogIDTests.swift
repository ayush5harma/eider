import Foundation
import XCTest
@testable import EiderKit

/// A source's id is accepted as text (CatalogIdentifier). These follow ids the
/// strict check refuses from the parser through the catalog to an install, and
/// show none of them becomes a path or the installed app's id.
final class SecurityCatalogIDTests: XCTestCase {
    private let sourceURL = URL(string: "https://src.example.com/odd.json")!
    private let tenKilobytes = String(repeating: "a.", count: 5120)
    /// What each id in the source is listed as after cleaning.
    private let listed = ["a+b~c", "../../x", "a/b", "xy", ".", "..", "/etc/passwd", "com.real.app"]

    private func sourceJSON() throws -> String {
        let raw = ["a+b~c", "../../x", "a/b", "x\u{0}y", ".", "..", "/etc/passwd", "com.real.app", tenKilobytes]
        let apps = raw.enumerated().map { index, id -> [String: Any] in
            ["name": "App \(index)", "bundleIdentifier": id,
             "versions": [["version": "1.0", "downloadURL": "https://cdn.example.com/app\(index).ipa"]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["name": "Odd", "apps": apps])
        return String(decoding: data, as: UTF8.self)
    }

    override func setUp() {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in StubURLProtocol.Reply(chunks: [Data("ipa bytes".utf8)]) }
    }

    override func tearDown() { StubURLProtocol.reset() }

    // MARK: Parse

    func testOddIDsAreListedCleanedAndATenKilobyteIDIsSkippedWithAShortWarning() throws {
        let source = try SourceParser.parse(data: Data(try sourceJSON().utf8), from: sourceURL)
        XCTAssertEqual(source.apps.map(\.bundleID), listed, "control characters are removed, nothing else changes")
        XCTAssertEqual(source.warnings.count, 1, "\(source.warnings)")
        let warning = try XCTUnwrap(source.warnings.first)
        XCTAssertTrue(warning.contains("longer than 255 bytes"), warning)
        XCTAssertLessThan(warning.utf8.count, 200, "the id is cut, not quoted whole")
    }

    // MARK: Parse -> catalog -> install from the source

    func testNoCatalogIDReachesAPathOrTheInstalledApp() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let fake = FakeFetch()
        fake.set(sourceURL, json: try sourceJSON())
        let calls = InstallCalls()
        let library = LibraryStore(paths: paths)
        let operations = AppOperations(
            sources: SourceStore(paths: paths, fetch: fake.fetch), library: library,
            downloads: DownloadManager(paths: paths, configuration: StubURLProtocol.configuration()),
            installIPA: { file, options, _ in
                calls.record(file, options)
                // The engine installs under the IPA's own validated id, never the catalog's.
                let app = InstalledApp(bundleID: "com.real.app", name: "Real", version: "1.0", build: "1",
                                       path: paths.home.appendingPathComponent("apps/Real.app"), sourceURL: options.sourceURL, options: options)
                try await library.record(app)
                return app
            },
            uninstaller: Uninstaller(store: library, containersDirectory: paths.home.appendingPathComponent("containers")))
        _ = try await operations.sources.add(url: sourceURL)

        let downloads = paths.downloads.resolvingSymlinksInPath()
        for id in listed {
            let entry = try await operations.catalogEntry(bundleID: id)
            let found = try XCTUnwrap(entry, id)
            XCTAssertEqual(found.app.bundleID, id)
            _ = try await operations.install(app: found.app, from: found.source)

            let call = try XCTUnwrap(calls.last, id)
            XCTAssertEqual(call.file.deletingLastPathComponent().resolvingSymlinksInPath(), downloads, "\(id): the file is directly in Downloads")
            XCTAssertTrue(FileManager.default.fileExists(atPath: call.file.path), id)
            if BundleIdentifier.isValid(id) {
                XCTAssertEqual(call.file.lastPathComponent, "\(id)-1.0.ipa", "a valid id keeps its readable name")
            } else {
                XCTAssertTrue(call.file.lastPathComponent.range(of: #"^id-[0-9a-f]{16}-1\.0\.ipa$"#, options: .regularExpression) != nil,
                              "\(id) -> \(call.file.lastPathComponent)")
            }
            XCTAssertEqual(call.options.expectedBundleID, id, "only compared with the IPA's id")
            XCTAssertNil(call.options.bundleID, "a catalog id never becomes the --bundle-id override")
        }

        let names = Set(calls.all.map(\.file.lastPathComponent))
        XCTAssertEqual(names.count, listed.count, "distinct ids never share a download file")
        let recorded = try await library.all()
        XCTAssertEqual(recorded.map(\.bundleID), ["com.real.app"])
        let stray = paths.home.deletingLastPathComponent().appendingPathComponent("x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "../../x did not escape")
        let home = try FileManager.default.contentsOfDirectory(atPath: paths.home.path).sorted()
        XCTAssertFalse(home.contains { $0 != "Downloads" && $0 != "Cache" && !$0.hasSuffix(".json") }, "\(home)")
    }

    func testAnOddCatalogIDNeverMatchesAnInstalledAppForUpdates() {
        let installed = InstalledApp(bundleID: "com.real.app", name: "Real", version: "1.0", build: "1",
                                     path: URL(fileURLWithPath: "/Applications/Real.app"), options: InstallOptions())
        let offers = ["com.real.app/", "../com.real.app", "com.real.app\u{200B}"].map { id in
            SourcedApp(
                source: CatalogSource(url: sourceURL, format: .altStore, name: "S"),
                app: CatalogApp(bundleID: CatalogIdentifier.cleaned(id) ?? id, name: "R",
                                versions: [CatalogVersion(version: "9.0", downloadURL: URL(string: "https://cdn.example.com/r.ipa")!)]))
        }
        // The zero-width space is removed at parse, so that one is the same app: an update.
        XCTAssertEqual(UpdateChecker.updates(installed: [installed], catalog: Array(offers.prefix(2))), [])
        XCTAssertEqual(UpdateChecker.updates(installed: [installed], catalog: [offers[2]]).count, 1)
    }

    // MARK: The download file name

    func testTheDownloadNameIsOnePlainBoundedComponent() {
        func name(_ id: String, _ version: String = "1.0") -> String {
            DownloadManager.fileName(
                for: CatalogApp(bundleID: id, name: "N", versions: []),
                version: CatalogVersion(version: version, downloadURL: URL(string: "https://cdn.example.com/a.ipa")!))
        }
        XCTAssertEqual(name("com.example.app"), "com.example.app-1.0.ipa", "unchanged for a valid id, so old downloads are reused")
        XCTAssertEqual(name("direct-0a1b2c3d4e5f"), "direct-0a1b2c3d4e5f-1.0.ipa")
        let longest = name(String(repeating: "a", count: BundleIdentifier.maxLength), String(repeating: "9", count: 4000))
        for candidate in [name("../../x"), name("a/b"), name("."), name(tenKilobytes), name("a+b~c", "../../.."), longest] {
            XCTAssertFalse(candidate.contains("/"), candidate)
            XCTAssertFalse(candidate.hasPrefix("."), candidate)
            XCTAssertLessThanOrEqual(candidate.utf8.count + 22, 255, "room for the .part suffix: \(candidate)")
        }
        XCTAssertNotEqual(name("a/b"), name("a_b"), "ids that the old character mapping merged stay apart")
        XCTAssertNotEqual(name("x", String(repeating: "1", count: 100)), name("x", String(repeating: "1", count: 101)))
    }

    // MARK: The engine

    func testTheEngineRefusesAnIPAThatIsNotTheOddIDAndTheOverrideIsTheOnlyWayPast() async throws {
        let scratch = try EngineScratch()
        let ipa = scratch.url("thing.ipa")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.real.app</string>
        <key>CFBundleExecutable</key><string>Exec</string>
        </dict></plist>
        """
        try CraftedZip.write([
            CraftedZip.Entry(name: "Payload/Thing.app/Info.plist", text: plist),
            CraftedZip.Entry(name: "Payload/Thing.app/Exec", text: "not a binary"),
        ], to: ipa)
        let shims = ShimLocator(environment: [ShimLocator.overrideVariable: try scratch.placeholderShims().path], executableURL: nil, resourceURL: nil)
        let installer = Installer(paths: EiderPaths(home: scratch.url("home")), shims: shims)
        let destination = scratch.url("apps")

        for odd in ["a+b~c", "../../x", "a/b", "."] {
            do {
                _ = try await installer.install(ipa: ipa, options: InstallOptions(destination: destination, expectedBundleID: odd))
                XCTFail("\(odd): expected a refusal")
            } catch let failure as InstallFailure {
                XCTAssertEqual(failure.code, .bundleIDMismatch, failure.message)
                XCTAssertTrue(failure.message.contains("--bundle-id com.real.app"), failure.message)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), odd)
        }
        // Past the check the fake binary fails at the Mach-O stage: that is the evidence.
        do {
            _ = try await installer.install(ipa: ipa, options: InstallOptions(destination: destination, bundleID: "com.real.app", expectedBundleID: "a+b~c"))
            XCTFail("expected the Mach-O stage to refuse the fake binary")
        } catch let failure as InstallFailure {
            XCTAssertEqual(failure.code, .noMachO, failure.message)
        }
    }
}

private final class InstallCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(file: URL, options: InstallOptions)] = []

    var all: [(file: URL, options: InstallOptions)] { lock.withLock { calls } }
    var last: (file: URL, options: InstallOptions)? { all.last }
    func record(_ file: URL, _ options: InstallOptions) { lock.withLock { calls.append((file, options)) } }
}
