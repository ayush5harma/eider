import Foundation

/// `InstallOptions.resetData`, as the legacy installer's `--reset` does it:
/// refuse while the app runs (a running copy would write its state straight
/// back), then empty the container's folders and drop its cached preferences.
/// The container's root is left in place: it belongs to containermanagerd and
/// cannot be moved or removed without Full Disk Access.
struct DataReset: Sendable {
    let containersDirectory: URL
    /// True when a process runs from a bundle called `<name>.app`.
    let isRunning: @Sendable (String) -> Bool

    static let standard = DataReset(
        containersDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true),
        isRunning: { !RunningProcesses.pids(pathContaining: "/\($0).app/").isEmpty }
    )

    /// Called as soon as the app's name is known, before the previous copy is
    /// trashed, so a refusal leaves everything as it was.
    func refuseIfRunning(name: String) throws {
        guard isRunning(name) else { return }
        throw InstallFailure(.appRunning, "Reset needs \(name) quit first: a running copy would write its state straight back.")
    }

    /// Returns a line to report, or nil when there was no container.
    func clear(bundleID: String) -> String? {
        let container = containersDirectory.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: container.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        dropCachedPreferences(in: container, bundleID: bundleID)
        let entries = (try? FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var cleared = 0
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if (try? FileManager.default.removeItem(at: entry)) != nil { cleared += 1 }
        }
        return "Cleared the app's data (\(cleared) folder(s) in its container)"
    }

    /// Through cfprefsd, so its cached copy of the container-scoped domain goes
    /// too: deleting only the plist brought the old values back on relaunch.
    private func dropCachedPreferences(in container: URL, bundleID: String) {
        let domain = container.appendingPathComponent("Library/Preferences/\(bundleID)").path as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return }
        CFPreferencesSetMultiple(nil, keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
