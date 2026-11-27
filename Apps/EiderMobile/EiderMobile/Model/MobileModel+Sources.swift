import EiderCore
import Foundation

extension MobileModel {
    /// How old a source's saved copy may get before launch fetches it again (the Mac's rule).
    static let staleSourceAge: TimeInterval = 6 * 3600

    func addSourceFromText() async {
        let text = newSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        // https only: a phone has no local source files to point at.
        guard let url = URL(string: text), URLPolicy.isAllowed(url) else {
            errorMessage = "That is not an address Eider can use. Enter an https address."
            return
        }
        if await addSource(url) { newSourceText = "" }
    }

    @discardableResult
    func addSource(_ url: URL) async -> Bool {
        isAddingSource = true
        defer { isAddingSource = false }
        do {
            try await sourceStore.add(url: url)
            refreshFailures[url] = nil
            await reloadCatalog()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func removeSource(_ source: CatalogSource) async {
        do {
            try await sourceStore.remove(url: source.url)
            if filter.source == source.url { filter.source = nil }
            refreshFailures[source.url] = nil
        } catch {
            report(error)
        }
        await reloadCatalog()
    }

    func refreshAllSources() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            record(try await sourceStore.refreshAll(), clearing: true)
        } catch {
            report(error)
        }
        await reloadCatalog()
    }

    /// At launch, only sources older than `staleSourceAge` or saved under an
    /// older merge rule, as on the Mac. A failed fetch keeps the old copy.
    func refreshStaleSources(now: Date = Date()) async {
        let stale = sources.filter { $0.isOverMerged || now.timeIntervalSince($0.fetchedAt) > Self.staleSourceAge }.map(\.url)
        guard !stale.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            record(try await sourceStore.refresh(urls: stale), clearing: false)
        } catch {
            report(error)
        }
        await reloadCatalog()
    }

    private func record(_ outcomes: [SourceRefreshResult], clearing: Bool) {
        var failures = clearing ? [:] : refreshFailures
        for outcome in outcomes {
            switch outcome.result {
            case .success: failures[outcome.url] = nil
            case .failure(let error):
                let failure = error.codedFailure
                failures[outcome.url] = "\(failure.message) (\(failure.code))"
            }
        }
        refreshFailures = failures
    }

    // MARK: Import and export

    /// Every new address in a list file or pasted text, the Mac's way: nothing
    /// is fetched for an address already added, rejected or repeated, and one
    /// source failing does not stop the rest.
    func importSources(from data: Data) async {
        guard !isAddingSource else { return }
        isAddingSource = true
        importProgress = nil
        defer {
            isAddingSource = false
            importProgress = nil
        }
        do {
            let store = sourceStore
            let result = try await SourceListIO.importList(
                data, existing: sources.map(\.url),
                add: { try await store.add(url: $0) },
                onProgress: { [weak self] done, total in
                    Task { @MainActor in
                        guard let self, self.isAddingSource, total > 0 else { return }
                        self.importProgress = (done, total)
                    }
                })
            await reloadCatalog()
            importResult = result
        } catch {
            report(error)
        }
    }

    func importSources(fromFile url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            await importSources(from: try SourceListIO.read(contentsOf: url))
        } catch {
            report(error)
        }
    }

    func exportedSourceList() throws -> Data {
        try SourceListIO.exportJSON(sources)
    }

    var allSourceURLsText: String { SourceListIO.exportText(sources) }

    func appCount(of source: CatalogSource) -> Int { source.entryCount ?? source.apps.count }
}
