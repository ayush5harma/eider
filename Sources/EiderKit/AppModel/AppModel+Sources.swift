import Foundation

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

    /// A web address, or a local path (a source kept in a file).
    static func sourceURL(from text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        guard let url = URL(string: text), URLPolicy.isAllowed(url, allowFile: true) else { return nil }
        return url
    }
}
