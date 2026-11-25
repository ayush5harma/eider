import Foundation

extension AppModel {
    // MARK: Library

    public func hasUpdate(_ app: InstalledApp) -> Bool {
        updates[app.bundleID] != nil
    }

    /// From Library the person is taken to Activity; the Updates page shows
    /// the progress in the row instead and stays where it is.
    public func update(_ app: InstalledApp, showActivity: Bool = true) {
        guard !isUpdating(app.bundleID) else { return }
        activity.start(.update(bundleID: app.bundleID, name: app.name))
        if showActivity { selection = .activity }
    }

    /// Every update, one after another, through Activity.
    public func updateAll() {
        let requests = updateList
            .filter { !isUpdating($0.installed.bundleID) }
            .map { InstallRequest.update(bundleID: $0.installed.bundleID, name: $0.installed.name) }
        guard !requests.isEmpty else { return }
        activity.startInSequence(requests)
    }

    /// The running or queued update of this app, if any.
    public func updateActivity(for bundleID: String) -> ActivityItem? {
        activity.items.first {
            guard $0.isPending, case .update(let id, _) = $0.request else { return false }
            return id == bundleID
        }
    }

    public func isUpdating(_ bundleID: String) -> Bool {
        updateActivity(for: bundleID) != nil
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

    /// The sentence under the Install button. The download module records the
    /// first SHA-256 it sees for an address and refuses a different file later.
    public func integrityNote(for version: CatalogVersion) -> String {
        version.sha256 == nil
            ? "This source does not supply a hash. The first download is recorded, and a later download that differs is refused."
            : "This source supplies a SHA-256. The download is checked against it before anything is installed."
    }
}
