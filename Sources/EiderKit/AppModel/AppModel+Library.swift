import Foundation

extension AppModel {
    // MARK: Library

    public func hasUpdate(_ app: InstalledApp) -> Bool {
        updates[app.bundleID] != nil
    }

    public func update(_ app: InstalledApp) {
        activity.start(.update(bundleID: app.bundleID, name: app.name))
        selection = .activity
    }

    public func uninstall(_ app: InstalledApp, removeData: Bool) async {
        do {
            try await backend.uninstall(bundleID: app.bundleID, removeData: removeData)
        } catch {
            report(error)
        }
        await reload()
    }

    /// Runs `LaunchProbe`, which opens the app, so the sheet can say what happened.
    public func diagnose(_ app: InstalledApp) async {
        diagnosis = .running(appName: app.name)
        let result = await backend.diagnose(app)
        diagnosis = .finished(appName: app.name, result: result)
    }

    public func dismissDiagnosis() {
        diagnosis = .idle
    }

    // MARK: Browse

    public var browseResults: [SourcedApp] {
        filter.apply(to: catalog)
    }

    public var selectedEntry: SourcedApp? {
        selectedAppID.flatMap { id in catalog.first { $0.id == id } }
    }

    public func status(of app: CatalogApp) -> InstallStatus {
        guard let local = installed.first(where: { $0.bundleID == app.bundleID }) else { return .notInstalled }
        if let update = updates[app.bundleID] {
            return .updateAvailable(from: local.version, to: update.version.version)
        }
        return .installed(version: local.version)
    }

    /// The sentence under the Install button. The download module records the
    /// first SHA-256 it sees for an address and refuses a different file later.
    public func integrityNote(for version: CatalogVersion) -> String {
        version.sha256 == nil
            ? "This source does not supply a hash. The first download is recorded, and a later download that differs is refused."
            : "This source supplies a SHA-256. The download is checked against it before anything is installed."
    }
}
