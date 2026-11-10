import Foundation
import XCTest
@testable import EiderKit

/// A scripted backend: whatever `script` does is what an install "does".
/// Everything else answers from fixed lists, so activity tests need no disk.
final class StubBackend: AppBackend, @unchecked Sendable {
    typealias Script = @Sendable (InstallRequest, Int, @Sendable (OperationEvent) -> Void) async throws -> InstalledApp?

    private let lock = NSLock()
    private var attempts = 0
    private var diagnosisResult = LaunchResult.running(pid: 1)
    let script: Script

    init(script: @escaping Script = { _, _, _ in nil }) { self.script = script }

    func installedApps() async throws -> [InstalledApp] { [] }
    func availableUpdates() async throws -> [AvailableUpdate] { [] }
    func catalog() async throws -> [SourcedApp] { [] }
    func sources() async throws -> [CatalogSource] { [] }
    func addSource(_ url: URL) async throws -> CatalogSource { throw CancellationError() }
    func removeSource(_ url: URL) async throws {}
    func refreshAllSources() async throws -> [SourceRefreshResult] { [] }
    func uninstall(bundleID: String, removeData: Bool) async throws {}
    func diagnose(_ app: InstalledApp) async -> LaunchResult { lock.withLock { diagnosisResult } }
    func setDiagnosis(_ result: LaunchResult) { lock.withLock { diagnosisResult = result } }

    func perform(
        _ request: InstallRequest, options: InstallOptions,
        onEvent: @escaping @Sendable (OperationEvent) -> Void
    ) async throws -> InstalledApp? {
        let attempt = lock.withLock { () -> Int in attempts += 1; return attempts }
        return try await script(request, attempt, onEvent)
    }
}

enum AppModelFixtures {
    static let sourceA = URL(string: "https://a.example.com/source.json")!
    static let sourceB = URL(string: "https://b.example.com/source.json")!

    static func installedApp(_ bundleID: String, name: String, version: String, source: URL? = sourceA, path: String = "/tmp/x.app") -> InstalledApp {
        InstalledApp(
            bundleID: bundleID, name: name, version: version, build: version,
            path: URL(fileURLWithPath: path), sourceURL: source, options: InstallOptions())
    }

    /// An AltStore document; each app is (bundle id, name, developer, versions newest first).
    static func altStore(name: String, apps: [(id: String, name: String, developer: String, versions: [String])]) -> String {
        let entries = apps.map { app -> String in
            let versions = app.versions.map {
                #"{"version":"\#($0)","buildVersion":"\#($0)","downloadURL":"https://cdn.example.com/\#(app.id)-\#($0).ipa"}"#
            }.joined(separator: ",")
            return #"{"name":"\#(app.name)","bundleIdentifier":"\#(app.id)","developerName":"\#(app.developer)","versions":[\#(versions)]}"#
        }.joined(separator: ",")
        return #"{"name":"\#(name)","apps":[\#(entries)]}"#
    }

    /// A model over a fresh temporary home, with its sources served by `fetch`.
    @MainActor
    static func liveModel(
        fetch: FakeFetch, release: ReleaseCheck = ReleaseCheck(fetch: { _ in throw CatalogFailure.fetchFailed("offline") })
    ) throws -> (model: AppModel, paths: EiderPaths) {
        let paths = try CatalogFixtures.temporaryHome()
        let backend = LiveBackend(paths: paths, fetch: fetch.fetch)
        return (AppModel(paths: paths, backend: backend, releaseCheck: release), paths)
    }
}
