import Foundation

public struct SourceRefreshResult: Sendable {
    public let url: URL
    public let result: Result<CatalogSource, Error>
}

/// The owner's list of added sources, persisted at `EiderPaths.sourcesFile`.
/// Each entry holds the last parsed copy, so browsing works offline.
public actor SourceStore {
    private struct FileContents: Codable {
        var version = 1
        var sources: [CatalogSource]
    }

    private let paths: EiderPaths
    private let fetch: SourceFetch
    /// Every change to the list goes through here, so the flattened catalog built
    /// from it is dropped at the same moment and can never be stale.
    private var cache: [CatalogSource]? {
        didSet { appsCache = nil }
    }
    /// `allApps()` serves search, update checks and every catalog lookup; with a
    /// 17k-app source, rebuilding it per call was the work, not the lookup.
    private var appsCache: [SourcedApp]?

    public init(paths: EiderPaths = EiderPaths(), fetch: @escaping SourceFetch = SourceFetcher.default) {
        self.paths = paths
        self.fetch = fetch
    }

    public var sources: [CatalogSource] {
        get throws { try current() }
    }

    /// Fetches, parses and saves. A URL already in the list is refreshed in place.
    @discardableResult
    public func add(url: URL) async throws -> CatalogSource {
        let source = try await Self.load(url, using: fetch)
        try store(source)
        return source
    }

    public func remove(url: URL) throws {
        var list = try current()
        guard list.contains(where: { $0.url == url }) else { throw CatalogFailure.unknownSource(url) }
        list.removeAll { $0.url == url }
        try persist(list)
    }

    @discardableResult
    public func refresh(url: URL) async throws -> CatalogSource {
        guard try current().contains(where: { $0.url == url }) else { throw CatalogFailure.unknownSource(url) }
        return try await add(url: url)
    }

    /// Fetches every source at once. One failure does not stop the others, and
    /// a failed source keeps its previous copy.
    public func refreshAll() async throws -> [SourceRefreshResult] {
        try await refresh(urls: try current().map(\.url))
    }

    /// Fetches the given sources at once (the app's launch check refreshes only
    /// the stale ones). An address not in the list is skipped; one failure does
    /// not stop the others, and a failed source keeps its previous copy.
    public func refresh(urls requested: [URL]) async throws -> [SourceRefreshResult] {
        let added = Set(try current().map(\.url))
        let urls = requested.filter { added.contains($0) }
        guard !urls.isEmpty else { return [] }
        let fetch = self.fetch
        let outcomes = await withTaskGroup(of: (URL, Result<CatalogSource, Error>).self) { group in
            for url in urls {
                group.addTask { (url, await Self.attempt(url, using: fetch)) }
            }
            var collected: [URL: Result<CatalogSource, Error>] = [:]
            for await (url, result) in group { collected[url] = result }
            return collected
        }

        var list = try current()
        var results: [SourceRefreshResult] = []
        for url in urls {
            guard let result = outcomes[url] else { continue }
            if case .success(let source) = result { replace(source, in: &list) }
            results.append(SourceRefreshResult(url: url, result: result))
        }
        try persist(list)
        return results
    }

    public func allApps() throws -> [SourcedApp] {
        if let appsCache { return appsCache }
        var taken = Set<String>()
        var apps: [SourcedApp] = []
        for source in try current() {
            for sourced in SourcedApp.entries(of: source) {
                apps.append(taken.insert(sourced.id).inserted ? sourced : Self.uniquely(sourced, among: &taken))
            }
        }
        appsCache = apps
        return apps
    }

    // MARK: Internals

    /// Rows and lookups are keyed by `SourcedApp.id`. Merging makes it unique within
    /// a source, so this only runs for a hand-edited file that lists one address
    /// twice (or a bundle id holding the "|" separator), or a copy saved before
    /// the current merge rule that still lists duplicates: the later copy gets "#2",
    /// "#3", ... in list order, so the same file always yields the same ids.
    private static func uniquely(_ sourced: SourcedApp, among taken: inout Set<String>) -> SourcedApp {
        var number = 2
        while !taken.insert("\(sourced.id)#\(number)").inserted { number += 1 }
        return SourcedApp(source: sourced.source, app: sourced.app, id: "\(sourced.id)#\(number)")
    }

    private static func load(_ url: URL, using fetch: SourceFetch) async throws -> CatalogSource {
        guard URLPolicy.isAllowed(url, allowFile: true, allowLoopback: true) else {
            throw CatalogFailure.blockedURL(url.absoluteString)
        }
        var source = try SourceParser.parse(data: try await fetch(url), from: url)
        source.fetchedAt = wholeSeconds(source.fetchedAt)
        return source
    }

    /// The file stores seconds since 1970 but a `Date` counts from 2001, and
    /// adding the 31-year offset rounds a fractional date to a neighbouring
    /// double about half the time (measured: 9 of 16 runs of the persistence
    /// test failed). Whole seconds are exact in both counts, and "last
    /// refreshed" is never shown finer than that.
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func attempt(_ url: URL, using fetch: SourceFetch) async -> Result<CatalogSource, Error> {
        do { return .success(try await load(url, using: fetch)) } catch { return .failure(error) }
    }

    /// Re-reads the list after the await so a concurrent change is not lost.
    private func store(_ source: CatalogSource) throws {
        var list = try current()
        replace(source, in: &list)
        try persist(list)
    }

    private func replace(_ source: CatalogSource, in list: inout [CatalogSource]) {
        if let index = list.firstIndex(where: { $0.url == source.url }) {
            list[index] = source
        } else {
            list.append(source)
        }
    }

    private func current() throws -> [CatalogSource] {
        if let cache { return cache }
        let list = try readFile()
        cache = list
        return list
    }

    private func readFile() throws -> [CatalogSource] {
        guard FileManager.default.fileExists(atPath: paths.sourcesFile.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: paths.sourcesFile)
        } catch {
            throw CatalogFailure.storeUnreadable(error.localizedDescription)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [] }
        do {
            // A copy saved before entries were merged is merged here, in memory;
            // the file is rewritten at the next change. A copy saved under an older
            // rule keeps its `mergeRule` (nil or 1) and is refetched, not repaired:
            // what that rule folded away is gone from the file.
            return try Self.decoder.decode(FileContents.self, from: data).sources.map(CatalogMerge.normalized)
        } catch {
            throw CatalogFailure.storeUnreadable("not valid JSON")
        }
    }

    private func persist(_ list: [CatalogSource]) throws {
        do {
            try paths.ensure()
            let data = try Self.encoder.encode(FileContents(sources: list))
            try data.write(to: paths.sourcesFile, options: .atomic)
        } catch {
            throw CatalogFailure.storeUnreadable("could not save: \(error.localizedDescription)")
        }
        cache = list
    }

    /// Seconds since 1970 round-trip a Date exactly; ISO 8601 text would drop
    /// the fraction and make a reloaded source compare unequal to the saved one.
    /// Compact, because the file is rewritten whole on every change: indented and
    /// key-sorted, one 17,430-app source made it 22 MB. Older indented files still
    /// read, since the decoder does not care about whitespace or key order. The file
    /// is mostly URLs, so slashes are not escaped either (`\/` reads the same).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
