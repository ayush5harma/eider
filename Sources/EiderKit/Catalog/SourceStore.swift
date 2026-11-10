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
    private var cache: [CatalogSource]?

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
        let urls = try current().map(\.url)
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
        try current().flatMap { source in source.apps.map { SourcedApp(source: source, app: $0) } }
    }

    // MARK: Internals

    private static func load(_ url: URL, using fetch: SourceFetch) async throws -> CatalogSource {
        guard URLPolicy.isAllowed(url, allowFile: true, allowLoopback: true) else {
            throw CatalogFailure.blockedURL(url.absoluteString)
        }
        return try SourceParser.parse(data: try await fetch(url), from: url)
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
            return try Self.decoder.decode(FileContents.self, from: data).sources
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
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
