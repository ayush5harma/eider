import EiderCore
import Foundation

/// The IPA library and the installed-app records. An actor so file moves and
/// JSON writes stay off the main actor; both lists are small.
actor LibraryStore {
    private let paths: EiderPaths

    init(paths: EiderPaths) {
        self.paths = paths
    }

    // MARK: IPAs

    func ipas() throws -> [LibraryIPA] {
        try JSONFile.read([LibraryIPA].self, from: paths.ipaIndexFile) ?? []
    }

    nonisolated func fileURL(of ipa: LibraryIPA) -> URL {
        paths.ipas.appendingPathComponent(ipa.fileName)
    }

    /// Takes a downloaded file (moved) or a shared one (copied, since the
    /// original belongs to whoever shared it), names it by a fresh id, and
    /// records it newest first.
    func add(fileAt source: URL, details: LibraryIPA.Details, move: Bool) throws -> LibraryIPA {
        guard source.pathExtension.lowercased() == "ipa" || move else { throw LibraryError.notAnIPA }
        try paths.ensureMobile()
        let id = UUID()
        let fileName = "\(id.uuidString).ipa"
        let destination = paths.ipas.appendingPathComponent(fileName)
        if move {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let ipa = LibraryIPA(
            id: id, fileName: fileName, name: details.name, bundleID: details.bundleID,
            version: details.version, build: details.build, size: size, addedAt: Date(),
            origin: details.origin, iconURL: details.iconURL, sha256: details.sha256)
        try JSONFile.write([ipa] + ipas(), to: paths.ipaIndexFile)
        return ipa
    }

    func remove(_ id: UUID) throws {
        var list = try ipas()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let removed = list.remove(at: index)
        try? FileManager.default.removeItem(at: fileURL(of: removed))
        try JSONFile.write(list, to: paths.ipaIndexFile)
    }

    /// What an install learned from the app itself, kept for the next one.
    func update(_ ipa: LibraryIPA) throws {
        var list = try ipas()
        guard let index = list.firstIndex(where: { $0.id == ipa.id }) else { return }
        list[index] = ipa
        try JSONFile.write(list, to: paths.ipaIndexFile)
    }

    // MARK: Installed apps

    func installed() throws -> [InstalledApp] {
        try JSONFile.read([InstalledApp].self, from: paths.installedFile) ?? []
    }

    /// One record per bundle id: installing again replaces the app on the
    /// device, so it replaces the record too.
    func record(_ app: InstalledApp) throws {
        let list = try installed().filter { $0.bundleID != app.bundleID }
        try JSONFile.write([app] + list, to: paths.installedFile)
    }

    func forget(bundleID: String) throws {
        try JSONFile.write(try installed().filter { $0.bundleID != bundleID }, to: paths.installedFile)
    }
}
