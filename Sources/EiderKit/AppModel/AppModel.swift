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
    public internal(set) var sources: [CatalogSource] = []
    public internal(set) var catalog: [SourcedApp] = []

    // Browse
    public var filter = BrowseFilter()
    public var selectedAppID: String?

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
    /// touches the network: that is `refreshAllSources()`, on the person's action.
    public func reload() async {
        do {
            installed = try await backend.installedApps()
            sources = try await backend.sources()
            catalog = try await backend.catalog()
            let available = try await backend.availableUpdates()
            updates = Dictionary(available.map { ($0.installed.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            report(error)
        }
    }

    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        let failure = OperationFailure.wrap(error)
        errorMessage = "\(failure.message) (\(failure.code))"
    }
}
