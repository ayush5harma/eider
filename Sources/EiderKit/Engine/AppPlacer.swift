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
    let emit: (String, Double) -> Void

    /// Returns where the app now is.
    func place(_ app: URL, name: String, bundleID: String, into destination: URL) throws -> URL {
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) } catch {
            throw InstallFailure(.destinationUnusable, "Cannot create \(destination.path): \(error.localizedDescription)")
        }
        guard FileManager.default.isWritableFile(atPath: destination.path) else {
            throw InstallFailure(.destinationUnusable, "\(destination.path) is not writable. Choose another folder.")
        }
        let target = destination.appendingPathComponent("\(name).app", isDirectory: true)
        try moveExistingCopyAside(target, bundleID: bundleID)
        if resetData, let note = reset.clear(bundleID: bundleID) { emit(note, 0.96) }
        do { try FileManager.default.moveItem(at: app, to: target) } catch {
            throw InstallFailure(.placementFailed, "Could not move the app into \(destination.path): \(error.localizedDescription)")
        }
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

    private func moveExistingCopyAside(_ target: URL, bundleID: String) throws {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        if !isRecorded(bundleID: bundleID, at: target), !force {
            let old = ["Info.plist", "Contents/Info.plist"].lazy
                .compactMap { try? InfoPlist(url: target.appendingPathComponent($0)) }.first?.string("CFBundleIdentifier")
            throw InstallFailure(
                .destinationConflict,
                "\(target.path) already exists and Eider did not install it (bundle id \(old ?? "unknown")). Use force to replace it, or choose another destination."
            )
        }
        do { _ = try trash(target) } catch {
            do { try FileManager.default.removeItem(at: target) } catch {
                throw InstallFailure(.placementFailed, "Cannot replace \(target.path): \(error.localizedDescription)")
            }
            emit("Could not use the Trash; the previous copy was deleted.", 0.95)
        }
        emit("Previous copy moved to the Trash", 0.95)
    }
}
