import Foundation

extension CatalogSource {
    /// The Sources tab's button: "1 warning", "18 warnings".
    public var warningsLabel: String {
        warnings.count == 1 ? "1 warning" : "\(warnings.count) warnings"
    }
}

public struct SourceImportProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public var label: String { "Importing \(done) of \(total)..." }
}

extension AppModel {
    public var selectedSource: CatalogSource? {
        selectedSourceURL.flatMap { url in sources.first { $0.url == url } }
    }

    /// Adds the address in the text field. The store fetches it once, which is
    /// the person's action; nothing here fetches on its own.
    public func addSourceFromText() async {
        let text = newSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.sourceURL(from: text) else {
            errorMessage = "That is not an address Eider can use. Enter an https address, or a file path."
            return
        }
        if await addSource(url) { newSourceText = "" }
    }

    @discardableResult
    func addSource(_ url: URL) async -> Bool {
        isAddingSource = true
        defer { isAddingSource = false }
        do {
            let source = try await backend.addSource(url)
            await reload()
            selectedSourceURL = source.url
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: Import and export

    /// Adds every new address in a list file or pasted text. Rides on
    /// `isAddingSource`, so the Add button and spinner behave as for one source.
    /// Nothing is fetched for an address already added, rejected by the URL
    /// policy or repeated in the list; one source failing does not stop the rest.
    public func importSources(from data: Data) async {
        guard !isAddingSource else { return }
        isAddingSource = true
        sourceImportProgress = nil
        defer {
            isAddingSource = false
            sourceImportProgress = nil
        }
        do {
            let backend = self.backend
            let result = try await SourceListIO.importList(
                data, existing: sources.map(\.url),
                add: { try await backend.addSource($0) },
                onProgress: { done, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.isAddingSource, total > 0 else { return }
                        self.sourceImportProgress = SourceImportProgress(done: done, total: total)
                    }
                })
            await reload()
            sourceImportResult = result
        } catch {
            report(error)
        }
    }

    public func importSources(fromFile url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            await importSources(from: try SourceListIO.read(contentsOf: url))
        } catch {
            report(error)
        }
    }

    /// The export file for a chosen name: plain text for ".txt", Eider JSON otherwise.
    public func sourceListFile(named name: String) throws -> Data {
        if name.lowercased().hasSuffix(".txt") { return Data(allSourceURLsText.utf8) }
        return try SourceListIO.exportJSON(sources)
    }

    /// Every source address, one per line.
    public var allSourceURLsText: String { SourceListIO.exportText(sources) }

    public func removeSource(_ source: CatalogSource) async {
        do {
            try await backend.removeSource(source.url)
            if selectedSourceURL == source.url { selectedSourceURL = nil }
            if filter.source == source.url { filter.source = nil }
            refreshFailures[source.url] = nil
        } catch {
            report(error)
        }
        await reload()
    }

    /// Fetches every source the person added; one failing does not stop the rest.
    public func refreshAllSources() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var failures: [URL: String] = [:]
            for outcome in try await backend.refreshAllSources() {
                if case .failure(let error) = outcome.result {
                    let failure = OperationFailure.wrap(error)
                    failures[outcome.url] = "\(failure.message) (\(failure.code))"
                }
            }
            refreshFailures = failures
        } catch {
            report(error)
        }
        await reload()
    }

    /// How old a source's saved copy may get before the launch check fetches it again.
    public static let staleSourceAge: TimeInterval = 6 * 3600

    /// At launch: fetch, in the background, only the sources whose copy is
    /// older than `staleSourceAge` or was saved under an older merge rule
    /// (`CatalogSource.isOverMerged`: its missing apps are only back after a
    /// fetch, so it does not wait out the age), then work out the updates again. The window
    /// is usable throughout (the fetch and the parse run off the main actor),
    /// and a failed fetch keeps the old copy and is shown on the Sources page.
    public func refreshStaleSources(now: Date = Date()) async {
        let stale = sources.filter { $0.isOverMerged || now.timeIntervalSince($0.fetchedAt) > Self.staleSourceAge }.map(\.url)
        guard !stale.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let outcomes = try await backend.refreshSources(stale)
            var failures = refreshFailures
            for outcome in outcomes {
                switch outcome.result {
                case .success: failures[outcome.url] = nil
                case .failure(let error):
                    let failure = OperationFailure.wrap(error)
                    failures[outcome.url] = "\(failure.message) (\(failure.code))"
                }
            }
            refreshFailures = failures
        } catch {
            report(error)
        }
        await reload()
    }

    /// A web address, or a local path (a source kept in a file).
    static func sourceURL(from text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        guard let url = URL(string: text), URLPolicy.isAllowed(url, allowFile: true) else { return nil }
        return url
    }
}
