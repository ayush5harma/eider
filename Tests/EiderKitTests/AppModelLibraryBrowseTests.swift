import Foundation
import XCTest
@testable import EiderKit

@MainActor
final class AppModelLibraryBrowseTests: XCTestCase {
    private typealias F = AppModelFixtures

    private func model(sourceA: String, sourceB: String? = nil) async throws -> (AppModel, EiderPaths) {
        let fake = FakeFetch()
        fake.set(F.sourceA, json: sourceA)
        if let sourceB { fake.set(F.sourceB, json: sourceB) }
        let (model, paths) = try F.liveModel(fetch: fake)
        await model.addSource(F.sourceA)
        if sourceB != nil { await model.addSource(F.sourceB) }
        return (model, paths)
    }

    private func record(_ apps: [InstalledApp], in paths: EiderPaths) async throws {
        let store = LibraryStore(paths: paths)
        for app in apps { try await store.record(app) }
    }

    func testLibraryShowsInstalledAppsAndOnlyTheOnesWithNewerVersionsGetABadge() async throws {
        let (model, paths) = try await model(sourceA: F.altStore(name: "A", apps: [
            ("com.one", "One", "Dev", ["2.0", "1.0"]), ("com.two", "Two", "Dev", ["1.0"]),
        ]))
        try await record([
            F.installedApp("com.one", name: "One", version: "1.0"),
            F.installedApp("com.two", name: "Two", version: "1.0"),
            F.installedApp("com.local", name: "Local", version: "3.0", source: nil),
        ], in: paths)
        await model.reload()

        XCTAssertEqual(model.installed.map(\.name), ["Local", "One", "Two"])
        XCTAssertEqual(model.installed.filter(model.hasUpdate).map(\.bundleID), ["com.one"])
        XCTAssertEqual(model.updates["com.one"]?.version.version, "2.0")
    }

    func testBrowseStatusSaysNotInstalledInstalledOrUpdate() async throws {
        let (model, paths) = try await model(sourceA: F.altStore(name: "A", apps: [
            ("com.one", "One", "Dev", ["2.0", "1.0"]), ("com.two", "Two", "Dev", ["1.0"]), ("com.three", "Three", "Dev", ["1.0"]),
        ]))
        try await record([
            F.installedApp("com.one", name: "One", version: "1.0"),
            F.installedApp("com.two", name: "Two", version: "1.0"),
        ], in: paths)
        await model.reload()

        let byID = Dictionary(uniqueKeysWithValues: model.catalog.map { ($0.app.bundleID, $0.app) })
        XCTAssertEqual(model.status(of: byID["com.one"]!), .updateAvailable(from: "1.0", to: "2.0"))
        XCTAssertEqual(model.status(of: byID["com.two"]!), .installed(version: "1.0"))
        XCTAssertEqual(model.status(of: byID["com.three"]!), .notInstalled)
    }

    func testBrowseSearchMatchesNameDeveloperAndBundleIDIgnoringCaseAndAccents() async throws {
        let (model, _) = try await model(sourceA: F.altStore(name: "A", apps: [
            ("com.zeta.app", "Zeta Notes", "Acme Studio", ["1"]), ("org.alpha", "Alpha Café", "Beta Works", ["1"]),
        ]))
        XCTAssertEqual(model.browseResults.map(\.app.name), ["Alpha Café", "Zeta Notes"], "sorted by name")

        model.filter.text = "ZETA"
        XCTAssertEqual(model.browseResults.map(\.app.name), ["Zeta Notes"])
        model.filter.text = "beta works"
        XCTAssertEqual(model.browseResults.map(\.app.name), ["Alpha Café"], "developer, every word must match")
        model.filter.text = "cafe"
        XCTAssertEqual(model.browseResults.map(\.app.name), ["Alpha Café"], "accent-insensitive")
        model.filter.text = "org."
        XCTAssertEqual(model.browseResults.map(\.app.bundleID), ["org.alpha"], "bundle id")
        model.filter.text = "nothing like this"
        XCTAssertTrue(model.browseResults.isEmpty)
    }

    func testBrowseCanBeFilteredBySourceAndTheSameBundleIDInTwoSourcesIsTwoRows() async throws {
        let (model, _) = try await model(
            sourceA: F.altStore(name: "A", apps: [("com.shared", "Shared", "Dev", ["1"]), ("com.only.a", "Only A", "Dev", ["1"])]),
            sourceB: F.altStore(name: "B", apps: [("com.shared", "Shared", "Dev", ["2"])]))
        XCTAssertEqual(model.browseResults.count, 3)
        XCTAssertEqual(Set(model.browseResults.map(\.id)).count, 3, "row identities are distinct")

        model.filter.source = F.sourceB
        XCTAssertEqual(model.browseResults.map(\.app.bundleID), ["com.shared"])
        model.filter.source = F.sourceA
        XCTAssertEqual(model.browseResults.count, 2)
    }

    func testIntegrityNoteSaysWhetherTheSourceSuppliesAHash() async throws {
        let (model, _) = try await model(sourceA: F.altStore(name: "A", apps: []))
        let url = URL(string: "https://cdn.example.com/a.ipa")!
        XCTAssertTrue(model.integrityNote(for: CatalogVersion(version: "1", downloadURL: url)).contains("first download is recorded"))
        XCTAssertTrue(model.integrityNote(for: CatalogVersion(version: "1", downloadURL: url, sha256: String(repeating: "a", count: 64))).contains("supplies a SHA-256"))
    }

    func testDiagnosisReportsTheProbeResultUntilDismissed() async throws {
        let backend = StubBackend()
        let paths = try CatalogFixtures.temporaryHome()
        let model = AppModel(paths: paths, backend: backend)
        let app = F.installedApp("com.one", name: "One", version: "1.0")
        let diagnosis = LaunchDiagnosis(code: .libraryNotLoaded, summary: "A library is missing.", evidence: ["dyld: ProbeKit"])
        backend.setDiagnosis(.failed(diagnosis))

        await model.diagnose(app)
        XCTAssertEqual(model.diagnosis, .finished(appName: "One", result: .failed(diagnosis)))
        model.dismissDiagnosis()
        XCTAssertEqual(model.diagnosis, .idle)
    }
}
