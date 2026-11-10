import Foundation

/// What a person asked to be installed. Kept whole on every activity row so a
/// failed or cancelled operation can be retried exactly as it was asked.
public enum InstallRequest: Equatable, Sendable {
    case catalog(app: CatalogApp, version: CatalogVersion?, source: CatalogSource)
    case url(URL)
    case localIPA(URL)
    case update(bundleID: String, name: String)

    /// A short name for the activity list.
    public var title: String {
        switch self {
        case .catalog(let app, let version, _):
            return [app.name, version?.version].compactMap { $0 }.joined(separator: " ")
        case .url(let url):
            return url.lastPathComponent.isEmpty ? (url.host ?? url.absoluteString) : url.lastPathComponent
        case .localIPA(let url):
            return url.lastPathComponent
        case .update(_, let name):
            return "Update \(name)"
        }
    }
}

/// The seam between the app's state and the library: the model talks to this,
/// `LiveBackend` forwards to `AppOperations`, and the tests script it. Every
/// throwing method throws `OperationFailure` (or `CancellationError`).
public protocol AppBackend: Sendable {
    func installedApps() async throws -> [InstalledApp]
    func availableUpdates() async throws -> [AvailableUpdate]
    func catalog() async throws -> [SourcedApp]
    func sources() async throws -> [CatalogSource]
    func addSource(_ url: URL) async throws -> CatalogSource
    func removeSource(_ url: URL) async throws
    func refreshAllSources() async throws -> [SourceRefreshResult]
    /// Nil when an update was asked for and nothing newer exists.
    func perform(
        _ request: InstallRequest, options: InstallOptions,
        onEvent: @escaping @Sendable (OperationEvent) -> Void
    ) async throws -> InstalledApp?
    func uninstall(bundleID: String, removeData: Bool) async throws
    func diagnose(_ app: InstalledApp) async -> LaunchResult
}

/// The real thing: `AppOperations` and `LaunchProbe`.
public struct LiveBackend: AppBackend {
    private let operations: AppOperations
    private let probe: LaunchProbe

    public init(operations: AppOperations = AppOperations(), probe: LaunchProbe = LaunchProbe()) {
        self.operations = operations
        self.probe = probe
    }

    public init(paths: EiderPaths, fetch: @escaping SourceFetch = SourceFetcher.default) {
        self.init(operations: AppOperations(paths: paths, sources: SourceStore(paths: paths, fetch: fetch)))
    }

    public func installedApps() async throws -> [InstalledApp] {
        try await wrapped { try await operations.library.all() }
    }

    public func availableUpdates() async throws -> [AvailableUpdate] {
        try await operations.availableUpdates()
    }

    public func catalog() async throws -> [SourcedApp] {
        try await wrapped { try await operations.sources.allApps() }
    }

    public func sources() async throws -> [CatalogSource] {
        try await wrapped { try await operations.sources.sources }
    }

    public func addSource(_ url: URL) async throws -> CatalogSource {
        try await wrapped { try await operations.sources.add(url: url) }
    }

    public func removeSource(_ url: URL) async throws {
        try await wrapped { try await operations.sources.remove(url: url) }
    }

    public func refreshAllSources() async throws -> [SourceRefreshResult] {
        try await wrapped { try await operations.sources.refreshAll() }
    }

    public func perform(
        _ request: InstallRequest, options: InstallOptions,
        onEvent: @escaping @Sendable (OperationEvent) -> Void
    ) async throws -> InstalledApp? {
        switch request {
        case .catalog(let app, let version, let source):
            return try await operations.install(app: app, version: version, from: source, options: options, onEvent: onEvent)
        case .url(let url):
            return try await operations.install(ipaURL: url, options: options, onEvent: onEvent)
        case .localIPA(let url):
            return try await operations.install(localIPA: url, options: options, onEvent: onEvent)
        case .update(let bundleID, _):
            return try await operations.update(bundleID: bundleID, onEvent: onEvent)
        }
    }

    public func uninstall(bundleID: String, removeData: Bool) async throws {
        try await operations.uninstall(bundleID: bundleID, removeData: removeData)
    }

    public func diagnose(_ app: InstalledApp) async -> LaunchResult {
        await probe.launch(app)
    }

    private func wrapped<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch is CancellationError { throw CancellationError() } catch { throw OperationFailure.wrap(error) }
    }
}
