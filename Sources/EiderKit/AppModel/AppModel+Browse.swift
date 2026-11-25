import Foundation

/// What decides that a reload brought a different catalog. Cheap on purpose:
/// comparing two `[SourcedApp]` compares each entry's whole source, which is
/// quadratic in the catalog. A refresh always moves a source's `fetchedAt`.
struct CatalogStamp: Equatable {
    struct Source: Equatable {
        let url: URL
        let fetchedAt: Date
        let appCount: Int
    }

    let sources: [Source]
    let count: Int
    let firstID: String?
    let lastID: String?

    init(sources: [CatalogSource], catalog: [SourcedApp]) {
        self.sources = sources.map { Source(url: $0.url, fetchedAt: $0.fetchedAt, appCount: $0.apps.count) }
        count = catalog.count
        firstID = catalog.first?.id
        lastID = catalog.last?.id
    }
}

extension AppModel {
    // MARK: Browse

    /// The entry the list has selected. A dictionary lookup, whatever the filter shows.
    public var selectedEntry: SourcedApp? {
        selectedAppID.flatMap { browseIndex.byID[$0] }
    }

    public func status(of app: CatalogApp) -> InstallStatus {
        guard let local = installedByBundleID[app.bundleID] else { return .notInstalled }
        if let update = updates[app.bundleID] {
            return .updateAvailable(from: local.version, to: update.version.version)
        }
        return .installed(version: local.version)
    }

    /// Resolves once the index and the filtered results have caught up with the
    /// catalog and the filter as they are now. The window never needs this; the
    /// tests and the snapshot runner do.
    public func settleBrowse() async {
        while let pending = indexTask ?? filterTask {
            await pending.value
        }
    }

    // MARK: Keeping the results current

    /// Takes a freshly loaded catalog. An unchanged one (every install and
    /// uninstall reloads) leaves the index and the published results alone.
    func setCatalog(_ loaded: [SourcedApp]) {
        let stamp = CatalogStamp(sources: sources, catalog: loaded)
        guard stamp != catalogStamp else { return }
        catalogStamp = stamp
        catalog = loaded
        rebuildBrowseIndex(from: loaded)
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

    func browseFilterChanged() {
        publishBrowseResults(debounced: true)
    }

    /// Unfiltered results are the index itself, published at once. Otherwise
    /// the filter runs off the main actor after `browseDebounce`, a newer change
    /// cancels it, and the result is published once.
    private func publishBrowseResults(debounced: Bool) {
        filterTask?.cancel()
        filterTask = nil
        filterGeneration += 1
        // While the index is rebuilding, its completion publishes with the filter as it is then.
        guard indexTask == nil else { return }
        let index = browseIndex
        let filter = filter
        if filter.isUnfiltered {
            browseResults = index.entries
            return
        }
        let generation = filterGeneration
        let delay = debounced ? browseDebounce : .zero
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
