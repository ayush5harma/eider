import Foundation

/// The last stage of an install: put the finished bundle at its destination,
/// replacing an earlier copy only when that is Eider's own or the caller said
/// `force`. Separate from the pipeline so it can be exercised without shims.
struct AppPlacer {
    let force: Bool
    let resetData: Bool
    let reset: DataReset
    /// What library.json recorded before this install began.
    let recorded: [InstalledApp]
    /// Moves a path to the Trash and says where it went.
    var trash: (URL) throws -> URL? = { try Trash.move($0) }
    var move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    let emit: (String, Double) -> Void

    /// Nothing destructive happens until the new copy is ready on the destination
    /// volume: stage it there, move the old copy to the Trash, move the new one into
    /// place, and put the old one back if that last move fails. The old copy is never
    /// deleted outright; with no Trash the install stops. Data is reset only once the
    /// new app is in place. Returns where the app now is.
    func place(_ app: URL, name: String, bundleID: String, into destination: URL) throws -> URL {
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) } catch {
            throw InstallFailure(.destinationUnusable, "Cannot create \(destination.path): \(error.localizedDescription)")
        }
        guard FileManager.default.isWritableFile(atPath: destination.path) else {
            throw InstallFailure(.destinationUnusable, "\(destination.path) is not writable. Choose another folder.")
        }
        let target = destination.appendingPathComponent("\(name).app", isDirectory: true)
        let replacing = FileManager.default.fileExists(atPath: target.path)
        if replacing { try requireOwnershipOrForce(of: target, bundleID: bundleID) }

        let staging = destination.appendingPathComponent(".eider-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("\(name).app", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try move(app, staged)
        } catch {
            throw InstallFailure(.placementFailed, "Could not copy the app into \(destination.path): \(error.localizedDescription)")
        }

        var trashed: URL?
        if replacing {
            do { trashed = try trash(target) } catch {
                throw InstallFailure(
                    .trashUnavailable,
                    "The previous copy of \(name) could not be moved to the Trash (\(error.localizedDescription)), so it was left in place and nothing was installed."
                )
            }
            emit("Previous copy moved to the Trash", 0.95)
        }
        do { try move(staged, target) } catch {
            throw InstallFailure(.placementFailed, "Could not move the app into \(destination.path): \(error.localizedDescription)" + restoreOldCopy(trashed, to: target, replacing: replacing))
        }
        if resetData, let note = reset.clear(bundleID: bundleID) { emit(note, 0.96) }
        return target
    }

    /// A bundle Eider did not install is somebody else's app, whatever bundle id
    /// it claims: replacing it needs `force`. Eider's own is replaced when the
    /// library recorded this bundle id at this path.
    func isRecorded(bundleID: String, at target: URL) -> Bool {
        let path = Self.canonical(target)
        return recorded.contains { $0.bundleID == bundleID && Self.canonical($0.path) == path }
    }

    private static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private func requireOwnershipOrForce(of target: URL, bundleID: String) throws {
        guard !isRecorded(bundleID: bundleID, at: target), !force else { return }
        let old = ["Info.plist", "Contents/Info.plist"].lazy
            .compactMap { try? InfoPlist(url: target.appendingPathComponent($0)) }.first?.string("CFBundleIdentifier")
        throw InstallFailure(
            .destinationConflict,
            "\(target.path) already exists and Eider did not install it (bundle id \(old ?? "unknown")). Use force to replace it, or choose another destination."
        )
    }

    /// What to add to the failure when the old copy had been trashed.
    private func restoreOldCopy(_ trashed: URL?, to target: URL, replacing: Bool) -> String {
        guard replacing else { return "" }
        guard let trashed else { return ". The previous copy is in the Trash." }
        do {
            try move(trashed, target)
            return ". The previous copy was put back."
        } catch {
            return ". The previous copy is in the Trash at \(trashed.path)."
        }
    }
}
