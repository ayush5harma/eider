import CryptoKit
import Foundation

/// Everything the CLI and the app do to apps, in one place so neither
/// reimplements the flow: download, install, update, uninstall, and the
/// lookups they need. Every throwing method throws `OperationFailure`
/// (or `CancellationError` when the calling task is cancelled).
public struct AppOperations: Sendable {
    /// Installs an IPA file and records it in the library.
    typealias IPAInstall = @Sendable (URL, InstallOptions, @escaping @Sendable (InstallEvent) -> Void) async throws -> InstalledApp

    /// The sources the owner added, and what they offer. Shared, so a refresh
    /// through it is seen by the next lookup.
    public let sources: SourceStore
    public let library: LibraryStore
    private let downloads: DownloadManager
    private let installIPA: IPAInstall
    private let uninstaller: Uninstaller

    public init(
        paths: EiderPaths = EiderPaths(),
        shims: ShimLocator = ShimLocator(),
        sources: SourceStore? = nil
    ) {
        let library = LibraryStore(paths: paths)
        let installer = Installer(paths: paths, shims: shims, store: library)
        self.init(
            sources: sources ?? SourceStore(paths: paths), library: library,
            downloads: DownloadManager(paths: paths),
            installIPA: { ipa, options, onEvent in try await installer.install(ipa: ipa, options: options, onEvent: onEvent) },
            uninstaller: Uninstaller(store: library))
    }

    init(sources: SourceStore, library: LibraryStore, downloads: DownloadManager, installIPA: @escaping IPAInstall, uninstaller: Uninstaller) {
        self.sources = sources
        self.library = library
        self.downloads = downloads
        self.installIPA = installIPA
        self.uninstaller = uninstaller
    }

    // MARK: Install

    /// Downloads `version` (the newest when nil) of `app` from `source`, then
    /// installs it. The source's address and the IPA's SHA-256 are recorded in
    /// the library next to the app.
    public func install(
        app: CatalogApp, version: CatalogVersion? = nil, from source: CatalogSource,
        options: InstallOptions = InstallOptions(),
        onEvent: @escaping @Sendable (OperationEvent) -> Void = { _ in }
    ) async throws -> InstalledApp {
        try await install(app: app, version: version, sourceURL: source.url, options: options, expectsCatalogID: true, onEvent: onEvent)
    }

    /// Installs from a direct https address (the `eider://install/` deep link).
    /// The same rules as any download: https, or http to this Mac, never a file URL.
    public func install(
        ipaURL: URL, options: InstallOptions = InstallOptions(),
        onEvent: @escaping @Sendable (OperationEvent) -> Void = { _ in }
    ) async throws -> InstalledApp {
        // An address the caller typed (the CLI, a file drop): loopback is theirs to ask for. A deep link
        // never gets here with one, DeepLink.parse refuses it.
        guard URLPolicy.isAllowed(ipaURL, allowLoopback: true) else { throw OperationFailure.badURL(ipaURL) }
        let name = ipaURL.lastPathComponent.isEmpty ? ipaURL.host ?? "app" : ipaURL.lastPathComponent
        let key = SHA256.hash(data: Data(ipaURL.absoluteString.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        // The downloads folder names files by bundle id and version; the real id
        // is only known once the IPA is open, so the address stands in for it.
        let app = CatalogApp(bundleID: "direct-\(key)", name: name, versions: [CatalogVersion(version: "direct", downloadURL: ipaURL)])
        return try await install(app: app, version: nil, sourceURL: ipaURL, options: options, expectsCatalogID: false, onEvent: onEvent)
    }

    /// Installs a `.ipa` already on this Mac.
    public func install(
        localIPA: URL, options: InstallOptions = InstallOptions(),
        onEvent: @escaping @Sendable (OperationEvent) -> Void = { _ in }
    ) async throws -> InstalledApp {
        do {
            var options = options
            options.ipaSHA256 = try Hashing.sha256(ofFileAt: localIPA)
            return try await installIPA(localIPA, options) { onEvent(.install($0, afterDownload: false)) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CocoaError {
            throw OperationFailure(code: "operations.unreadable_file", message: "Could not read \(localIPA.path): \(error.localizedDescription)")
        } catch {
            throw OperationFailure.wrap(error)
        }
    }

    // MARK: Update

    /// Reinstalls the newest catalog version of an installed app, with the
    /// options it was installed with. The app's data is kept (a reset is never
    /// repeated). Returns nil when no source offers anything newer.
    public func update(
        bundleID: String, onEvent: @escaping @Sendable (OperationEvent) -> Void = { _ in }
    ) async throws -> InstalledApp? {
        do {
            guard let installed = try await library.app(bundleID: bundleID) else { throw OperationFailure.notInstalled(bundleID) }
            let catalog = try await sources.allApps()
            guard catalog.contains(where: { $0.app.bundleID == bundleID }) else { throw OperationFailure.notInCatalog(bundleID) }
            guard let update = UpdateChecker.update(for: installed, in: catalog) else { return nil }
            var options = installed.options
            options.resetData = false
            options.force = false
            return try await install(app: update.app, version: update.version, sourceURL: update.sourceURL, options: options, expectsCatalogID: true, onEvent: onEvent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OperationFailure.wrap(error)
        }
    }

    /// Installed apps that a source offers a newer version of. Reads the saved
    /// copies of the sources; refresh them first (`sources.refreshAll()`) for news.
    public func availableUpdates() async throws -> [AvailableUpdate] {
        do {
            return UpdateChecker.updates(installed: try await library.all(), catalog: try await sources.allApps())
        } catch {
            throw OperationFailure.wrap(error)
        }
    }

    // MARK: Uninstall

    /// Moves the app (and, when asked, its data folder) to the Trash and forgets it.
    public func uninstall(bundleID: String, removeData: Bool = false) async throws {
        do {
            try await uninstaller.uninstall(bundleID: bundleID, removeData: removeData)
        } catch {
            throw OperationFailure.wrap(error)
        }
    }

    // MARK: Lookups

    /// The first source (in the order they were added) that lists `bundleID`.
    public func catalogEntry(bundleID: String) async throws -> SourcedApp? {
        do {
            return try await sources.allApps().first { $0.app.bundleID == bundleID }
        } catch {
            throw OperationFailure.wrap(error)
        }
    }

    // MARK: Download then install

    private func install(
        app: CatalogApp, version: CatalogVersion?, sourceURL: URL, options: InstallOptions, expectsCatalogID: Bool,
        onEvent: @escaping @Sendable (OperationEvent) -> Void
    ) async throws -> InstalledApp {
        do {
            let release = try Self.pick(version, of: app)
            // Source entries are vetted when parsed; this also covers a copy saved before that rule.
            guard URLPolicy.isAllowed(release.downloadURL, allowLoopback: URLPolicy.isLoopbackURL(sourceURL)) else {
                throw OperationFailure.badURL(release.downloadURL)
            }
            var options = options
            options.sourceURL = sourceURL
            // A direct address has a made-up id; a catalog entry's id is the app the user chose.
            options.expectedBundleID = expectsCatalogID ? app.bundleID : nil
            var mapper = DownloadEventMapper(label: "\(app.name) \(release.version)")
            var file: URL?
            for try await event in downloads.download(release, of: app) {
                if case .finished(let url, let sha256) = event {
                    file = url
                    options.ipaSHA256 = sha256
                }
                if let mapped = mapper.map(event) { onEvent(mapped) }
            }
            guard let file else {
                throw OperationFailure(code: "operations.no_download", message: "The download ended without a file. Try again.")
            }
            return try await installIPA(file, options) { onEvent(.install($0, afterDownload: true)) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OperationFailure.wrap(error)
        }
    }

    private static func pick(_ requested: CatalogVersion?, of app: CatalogApp) throws -> CatalogVersion {
        if let requested { return requested }
        guard let newest = UpdateChecker.newestVersion(of: app) else {
            throw OperationFailure(code: "operations.no_version", message: "\(app.name) has no downloadable version in its source.")
        }
        return newest
    }

    /// The version of `app` whose version string is exactly `text`.
    public static func version(_ text: String, of app: CatalogApp) throws -> CatalogVersion {
        guard let match = app.versions.first(where: { $0.version == text }) else {
            throw OperationFailure.noSuchVersion(text, available: app.versions.map(\.version))
        }
        return match
    }
}
