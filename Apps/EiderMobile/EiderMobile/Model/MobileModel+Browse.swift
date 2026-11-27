import EiderCore
import Foundation

extension MobileModel {
    /// The search text waits this long after the last keystroke, so typing a
    /// word filters once rather than once per letter.
    static let browseDebounce: Duration = .milliseconds(150)

    /// Sources and their flattened catalog from the store (an actor, so the
    /// JSON decode is not on the main actor), then the index off the main actor.
    func reloadCatalog() async {
        do {
            let store = sourceStore
            let loadedSources = try await store.sources
            let loaded = try await store.allApps()
            sources = loadedSources
            catalog = loaded
            rebuildBrowseIndex(from: loaded)
            await recomputeUpdates()
        } catch {
            report(error)
        }
    }

    func entry(id: String) -> SourcedApp? { browseIndex.byID[id] }

    /// The installed record for a listed entry, matched the Mac's way: a tweak
    /// source lists many apps under one id, so an install from a differently
    /// named entry of the same source is not this one.
    func status(of entry: SourcedApp) -> InstallStatus {
        let local = installed.first { app in
            if let origin = app.origin {
                return origin.sourceURL == entry.sourceURL && origin.entryID == entry.app.bundleID
                    && (origin.entryName.map { CatalogApp.nameKey($0) == entry.app.nameKey } ?? true)
            }
            return app.bundleID == entry.app.bundleID
        }
        guard let local else { return .notInstalled }
        if let offer = updates.first(where: { $0.installed.bundleID == local.bundleID }) {
            return .updateAvailable(from: local.version, to: offer.version.version)
        }
        return .installed(version: local.version)
    }

    private func rebuildBrowseIndex(from loaded: [SourcedApp]) {
        indexGeneration += 1
        let generation = indexGeneration
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) { BrowseIndex(loaded) }.value
            guard let self, generation == self.indexGeneration else { return }
            self.browseIndex = index
            self.indexTask = nil
            self.publishBrowseResults(debounced: false)
        }
    }

    /// Unfiltered results are the index itself; a filter runs detached after
    /// the debounce and a newer change cancels it.
    func publishBrowseResults(debounced: Bool) {
        filterTask?.cancel()
        filterTask = nil
        filterGeneration += 1
        guard indexTask == nil else { return }
        let index = browseIndex
        let filter = filter
        if filter.isUnfiltered {
            browseResults = index.entries
            return
        }
        let generation = filterGeneration
        let delay = debounced ? Self.browseDebounce : .zero
        filterTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) { index.results(for: filter) }.value
            guard !Task.isCancelled, let self, generation == self.filterGeneration else { return }
            self.browseResults = results
            self.filterTask = nil
        }
    }
}
