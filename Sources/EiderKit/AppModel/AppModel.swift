import Foundation
import Observation

public enum DiagnosisState: Equatable, Sendable {
    case idle
    case running(appName: String)
    case finished(appName: String, result: LaunchResult)
}

/// Everything the window shows. No SwiftUI here: the views read these
/// properties and call these methods, and the unit tests drive the same ones.
/// Stored properties live in this file (the `@Observable` macro requires it);
/// the behaviour is split into the `AppModel+*` extensions by section.
@MainActor @Observable
public final class AppModel {
    public var selection: SidebarSection = .library

    public internal(set) var installed: [InstalledApp] = []
    public internal(set) var updates: [String: AvailableUpdate] = [:]
    /// The same updates in library order, for the Updates list.
    public internal(set) var updateList: [AvailableUpdate] = []
    /// Apps installed or updated in the last 30 days, newest first, without
    /// those that have an update waiting: the Updates page's lower section.
    public internal(set) var recentInstalls: [InstalledApp] = []
    /// When the sources' saved copies were last fetched (the newest of them):
    /// what the update list is as fresh as. Nil with no sources.
    public internal(set) var lastUpdateCheck: Date?
    public internal(set) var sources: [CatalogSource] = []
    public internal(set) var catalog: [SourcedApp] = []

    // Browse. `browseResults` is stored, not computed: a computed one sorted the
    // whole catalog on the main actor at every read. AppModel+Browse.swift keeps
    // it, `browseIndex` and `installedByBundleID` current.
    public var filter = BrowseFilter() {
        didSet { if filter != oldValue { browseFilterChanged() } }
    }
    public var selectedAppID: String?
    public internal(set) var browseResults: [SourcedApp] = []
    var browseIndex = BrowseIndex.empty
    var installedByBundleID: [String: InstalledApp] = [:]
    /// How long a change of query or source waits for the next one before the
    /// filter runs. Tests set it to zero.
    @ObservationIgnored public var browseDebounce = Duration.milliseconds(150)
    @ObservationIgnored var catalogStamp: CatalogStamp?
    @ObservationIgnored var indexTask: Task<Void, Never>?
    @ObservationIgnored var indexGeneration = 0
    @ObservationIgnored var filterTask: Task<Void, Never>?
    @ObservationIgnored var filterGeneration = 0
    @ObservationIgnored var reloadGeneration = 0

    // Sources
    public var newSourceText = ""
    public var selectedSourceURL: URL?
    public internal(set) var isRefreshing = false
    public internal(set) var isAddingSource = false
    /// Why a source's last refresh failed, by source address.
    public internal(set) var refreshFailures: [URL: String] = [:]

    // Sheets and alerts
    public var pendingInstall: PendingInstall?
    public internal(set) var pendingLink: DeepLink?
    public internal(set) var diagnosis = DiagnosisState.idle
    public internal(set) var releaseCheck = ReleaseCheckState.idle
    public var errorMessage: String?
    /// What the last interface-size change will do, for the Library to show.
    public var interfaceScaleNotice: String?

    public internal(set) var settings: AppSettings

    public let activity: ActivityModel

    @ObservationIgnored let backend: AppBackend
    @ObservationIgnored let paths: EiderPaths
    @ObservationIgnored let releaseChecker: ReleaseCheck

    public init(
        paths: EiderPaths = EiderPaths(), backend: AppBackend? = nil,
        releaseCheck: ReleaseCheck = ReleaseCheck()
    ) {
        let backend = backend ?? LiveBackend(paths: paths)
        self.paths = paths
        self.backend = backend
        self.releaseChecker = releaseCheck
        self.settings = AppSettings.load(from: paths)
        var reload: (@MainActor () -> Void)?
        self.activity = ActivityModel(backend: backend, onFinished: { _ in reload?() })
        reload = { [weak self] in Task { await self?.reload() } }
    }

    // MARK: Loading

    /// Reads the library and the saved copies of the sources from disk. Never
    /// touches the network: that is `refreshAllSources()`, on the person's
    /// action, and `refreshStaleSources()` at launch. The update list is
    /// worked out off the main actor from what was just read, and only the
    /// newest reload publishes, so a slow one never overwrites a later one.
    public func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let loadedInstalled = try await backend.installedApps()
            installed = loadedInstalled
            installedByBundleID = Dictionary(
                loadedInstalled.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
            sources = try await backend.sources()
            lastUpdateCheck = sources.map(\.fetchedAt).max()
            let loadedCatalog = try await backend.catalog()
            setCatalog(loadedCatalog)
            let found = await Task.detached(priority: .userInitiated) {
                UpdateChecker.updates(installed: loadedInstalled, catalog: loadedCatalog)
            }.value
            guard generation == reloadGeneration else { return }
            publishUpdates(found, installed: loadedInstalled)
        } catch {
            report(error)
        }
    }

    private func publishUpdates(_ found: [AvailableUpdate], installed: [InstalledApp], now: Date = Date()) {
        let byID = Dictionary(found.map { ($0.installed.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        if byID != updates { updates = byID }
        if found != updateList { updateList = found }
        let recent = Array(installed
            .filter { byID[$0.bundleID] == nil && now.timeIntervalSince($0.installedAt) < Self.recentInstallWindow }
            .sorted { $0.installedAt > $1.installedAt }
            .prefix(Self.recentInstallLimit))
        if recent != recentInstalls { recentInstalls = recent }
    }

    static let recentInstallWindow: TimeInterval = 30 * 24 * 3600
    static let recentInstallLimit = 12

    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        let failure = OperationFailure.wrap(error)
        errorMessage = "\(failure.message) (\(failure.code))"
    }
}
