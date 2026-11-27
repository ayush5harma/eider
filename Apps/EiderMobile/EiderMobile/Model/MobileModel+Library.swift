import EiderCore
import Foundation

extension MobileModel {
    func reloadLibrary() async {
        do {
            ipas = try await library.ipas()
            installed = try await library.installed()
        } catch {
            report(error)
        }
        await recomputeUpdates()
    }

    /// The Mac's matching rule over this device's records, off the main actor:
    /// a big catalog times the library is real work.
    func recomputeUpdates() async {
        let installed = installed
        let catalog = catalog
        updates = await Task.detached(priority: .utility) {
            UpdateChecker.updates(installed: installed, catalog: catalog)
        }.value
    }

    // MARK: Downloads

    /// Get: download the version into the library, then open the Install sheet.
    func get(_ entry: SourcedApp, version: CatalogVersion? = nil) async {
        guard let version = version ?? UpdateChecker.newestVersion(of: entry.app) ?? entry.app.latest else { return }
        guard let ipa = await download(version, of: entry.app, from: entry.source, key: entry.id) else { return }
        installRequest = InstallRequest(ipa: ipa)
    }

    func update(_ offer: UpdateOffer<InstalledApp>) async {
        guard let source = sources.first(where: { $0.url == offer.sourceURL }),
              let ipa = await download(offer.version, of: offer.app, from: source, key: offer.id)
        else { return }
        installRequest = InstallRequest(ipa: ipa, replacing: offer.installed)
    }

    /// Every update in turn with the default certificate and each app's own
    /// bundle id, no sheet per app; each row shows its own steps.
    func updateAll() async {
        guard !isUpdatingAll else { return }
        guard let certificate = defaultCertificate else {
            errorMessage = "Add a certificate first. Update All signs with the default certificate."
            tab = .certificates
            return
        }
        isUpdatingAll = true
        defer { isUpdatingAll = false }
        for offer in updates {
            guard let source = sources.first(where: { $0.url == offer.sourceURL }),
                  let ipa = await download(offer.version, of: offer.app, from: source, key: offer.id)
            else { continue }
            let job = InstallJob()
            updateJobs[offer.id] = job
            var options = SignOptions()
            options.bundleIdentifier = offer.installed.bundleID
            await job.run(
                .init(ipa: ipa, ipaURL: library.fileURL(of: ipa), certificate: certificate, options: options),
                model: self)
            if job.installed != nil { updateJobs[offer.id] = nil }
        }
    }

    func isDownloading(_ key: String) -> Bool { transfers[key] != nil }

    /// Through DownloadManager (https, size cap, hash checks, resumable), then
    /// moved into the library with what the catalog says about it.
    func download(_ version: CatalogVersion, of app: CatalogApp, from source: CatalogSource, key: String) async -> LibraryIPA? {
        guard transfers[key] == nil else { return nil }
        // DownloadManager allows loopback because its callers vet it: a remote
        // source must not make Eider call a service on this device.
        if URLPolicy.isLoopbackURL(version.downloadURL), !URLPolicy.isLoopbackURL(source.url) {
            report(DownloadFailure.blockedURL(version.downloadURL.absoluteString))
            return nil
        }
        transfers[key] = Transfer()
        defer { transfers[key] = nil }
        do {
            var finished: (file: URL, sha256: String)?
            for try await event in downloads.download(version, of: app) {
                switch event {
                case .started(let expected):
                    transfers[key] = Transfer(received: 0, expected: expected ?? version.size)
                case .progress(let received, let expected):
                    transfers[key] = Transfer(received: received, expected: expected ?? version.size)
                case .finished(let file, let sha256):
                    finished = (file, sha256)
                }
            }
            guard let finished else { return nil }
            let details = LibraryIPA.Details(
                name: app.name, bundleID: app.bundleID, version: version.version, build: version.build,
                origin: InstallOrigin(sourceURL: source.url, entryID: app.bundleID, entryName: app.name),
                iconURL: app.iconURL, sha256: finished.sha256)
            let ipa = try await library.add(fileAt: finished.file, details: details, move: true)
            ipas = try await library.ipas()
            return ipa
        } catch {
            report(error)
            return nil
        }
    }

    /// An `eider://install/<url>` link the person confirmed: a bare IPA address
    /// with no catalog entry, so it is described by its file name.
    func getLinkedIPA(_ url: URL) async {
        let name = url.deletingPathExtension().lastPathComponent
        let app = CatalogApp(bundleID: "link.\(abs(url.absoluteString.hashValue))", name: name.isEmpty ? "Linked App" : name, versions: [])
        let version = CatalogVersion(version: "", downloadURL: url)
        let source = CatalogSource(url: url, format: .altStore, name: url.host ?? "Link", apps: [], news: [], warnings: [], fetchedAt: Date())
        guard var ipa = await download(version, of: app, from: source, key: url.absoluteString) else { return }
        // A link is not a catalog entry, so nothing for Updates to follow.
        ipa.origin = nil
        ipa.bundleID = nil
        ipa.version = nil
        try? await library.update(ipa)
        ipas = (try? await library.ipas()) ?? ipas
        installRequest = InstallRequest(ipa: ipa)
    }

    // MARK: Library

    func importIPA(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "ipa" else {
            report(LibraryError.notAnIPA)
            return
        }
        do {
            let name = DisplayText.sanitized(url.deletingPathExtension().lastPathComponent)
            _ = try await library.add(fileAt: url, details: .init(name: name), move: false)
            ipas = try await library.ipas()
            tab = .library
        } catch {
            report(error)
        }
    }

    func deleteIPA(_ ipa: LibraryIPA) async {
        do {
            try await library.remove(ipa.id)
            ipas = try await library.ipas()
        } catch {
            report(error)
        }
    }

    /// Stops tracking an app; the app itself stays on the device (iOS removes
    /// apps from the Home Screen, not from here).
    func forget(_ app: InstalledApp) async {
        do {
            try await library.forget(bundleID: app.bundleID)
        } catch {
            report(error)
        }
        await reloadLibrary()
    }

    /// Called by an InstallJob that reached the device.
    func didInstall(_ record: InstalledApp, from ipa: LibraryIPA, info: BundleInfo) async {
        var learned = ipa
        learned.bundleID = info.bundleID
        learned.version = info.version
        learned.build = info.build
        if learned.origin == nil { learned.name = info.name }
        do {
            try await library.record(record)
            try await library.update(learned)
        } catch {
            report(error)
        }
        await reloadLibrary()
    }

    func sourceName(for url: URL?) -> String? {
        guard let url else { return nil }
        return sources.first { $0.url == url }?.name
    }
}
