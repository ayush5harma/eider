import Foundation

public struct UninstallFailure: Error, Sendable, Equatable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Moves an installed app, and on request its sandbox container, to the Trash
/// and forgets it. Nothing is deleted outright, so a mistake can be undone from the Finder.
public struct Uninstaller: Sendable {
    private let store: LibraryStore
    private let containersDirectory: URL

    public init(
        store: LibraryStore,
        containersDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
    ) {
        self.store = store
        self.containersDirectory = containersDirectory
    }

    /// The app is removed first and the registry entry with it; the container is
    /// then attempted, and a refusal (macOS guards containers) is reported
    /// without bringing the app back.
    public func uninstall(bundleID: String, removeData: Bool = false) async throws {
        // The id becomes a path below (the container), so it is checked before anything else.
        guard BundleIdentifier.isValid(bundleID) else {
            throw UninstallFailure(message: "\(bundleID) is not a valid bundle id (dot-separated letters, digits, - and _), so nothing was removed.")
        }
        guard let app = try await store.app(bundleID: bundleID) else {
            throw UninstallFailure(message: "No installed app has the bundle id \(bundleID).")
        }
        if FileManager.default.fileExists(atPath: app.path.path) {
            do { try Trash.move(app.path) } catch {
                throw UninstallFailure(message: "Could not move \(app.path.lastPathComponent) to the Trash: \(error.localizedDescription)")
            }
        }
        try await store.remove(bundleID: bundleID)
        guard removeData else { return }
        let container = containersDirectory.appendingPathComponent(bundleID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: container.path) else { return }
        do { try Trash.move(container) } catch {
            throw UninstallFailure(
                message: "The app was removed, but its data folder could not be moved to the Trash (macOS may need Full Disk Access for this): \(error.localizedDescription)"
            )
        }
    }
}
