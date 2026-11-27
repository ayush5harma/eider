import Foundation

/// Why a list could not be read at all. A single bad address is not one of
/// these: it is reported in the result and the rest of the list goes on.
public enum SourceListError: Error, Equatable, Sendable {
    case tooLarge(limit: Int)
    case tooManyEntries(limit: Int)
    case notText
    case unreadable(String)
    case unsupported(String)
    case noEntries

    public var code: String {
        switch self {
        case .tooLarge: return "sources.import_too_large"
        case .tooManyEntries: return "sources.import_too_many"
        case .notText, .unreadable, .unsupported: return "sources.import_unreadable"
        case .noEntries: return "sources.import_empty"
        }
    }

    public var message: String {
        switch self {
        case .tooLarge(let limit):
            return "That file is larger than \(limit / 1024 / 1024) MB, which is more than a list of sources needs."
        case .tooManyEntries(let limit):
            return "That list has more than \(limit) addresses. Split it and import the parts one at a time."
        case .notText:
            return "That file is not text. Eider reads a plain list of addresses or a JSON file."
        case .unreadable(let detail):
            return "That file is not a list Eider can read: \(detail)"
        case .unsupported(let detail):
            return detail
        case .noEntries:
            return "That file lists no sources."
        }
    }
}

extension SourceListError: LocalizedError {
    public var errorDescription: String? { message }
}

public struct SourceListRejection: Equatable, Sendable, Codable {
    public let url: String
    public let reason: String

    public init(url: String, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct SourceListFailure: Equatable, Sendable, Codable {
    public let url: String
    public let error: String

    public init(url: String, error: String) {
        self.url = url
        self.error = error
    }
}

/// What reading a list produced, before anything is fetched: the usable
/// addresses in file order (each once), and the entries that were refused.
public struct ParsedSourceList: Equatable, Sendable {
    public let urls: [URL]
    /// Addresses the file listed more than once, beyond the first time.
    public let repeated: [URL]
    public let rejected: [SourceListRejection]
}

/// The outcome of an import, shared by the app and the command line so both
/// say the same thing. `alreadyPresent` holds both an address already in the
/// owner's list and one the file itself repeated: neither needed any work.
public struct SourceImportResult: Equatable, Sendable, Codable {
    public var added: [String]
    public var alreadyPresent: [String]
    public var rejected: [SourceListRejection]
    public var failed: [SourceListFailure]

    public init(
        added: [String] = [], alreadyPresent: [String] = [],
        rejected: [SourceListRejection] = [], failed: [SourceListFailure] = []
    ) {
        self.added = added
        self.alreadyPresent = alreadyPresent
        self.rejected = rejected
        self.failed = failed
    }

    /// "Added 3 · 2 already added · 1 rejected"; a part with nothing in it is left out, except the first.
    public var summary: String {
        var parts = ["Added \(added.count)"]
        if !alreadyPresent.isEmpty { parts.append("\(alreadyPresent.count) already added") }
        if !rejected.isEmpty { parts.append("\(rejected.count) rejected") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// One line per rejected or failed address, with its reason.
    public var problemLines: [String] {
        rejected.map { "rejected: \($0.url): \($0.reason)" } + failed.map { "failed: \($0.url): \($0.error)" }
    }

    public var hasProblems: Bool { !rejected.isEmpty || !failed.isEmpty }
}

/// Export and import of the source list as a file. Only addresses (and names,
/// for a person reading the file) are written, because each source's apps are
/// fetched again when it is added.
public enum SourceListIO {
    /// A list of addresses is a few hundred bytes a line at most; a megabyte
    /// is far past any real list and bounds what a pasted or dropped file can cost.
    public static let maxBytes = 1024 * 1024
    /// Each one is a network fetch, so the count is capped as well as the size.
    public static let maxEntries = 500
    /// How many sources are fetched at once while importing.
    public static let maxConcurrentFetches = 4
    static let maxAddressLength = 2048

    public static let jsonFormat = "eider-sources"
    public static let jsonVersion = 1

    // MARK: Export

    private struct ExportFile: Codable {
        struct Entry: Codable {
            let url: String
            let name: String
        }
        let format: String
        let version: Int
        let exported: String
        let sources: [Entry]
    }

    public static func exportJSON(_ sources: [CatalogSource], now: Date = Date()) throws -> Data {
        let file = ExportFile(
            format: jsonFormat, version: jsonVersion,
            exported: ISO8601DateFormatter().string(from: now),
            sources: sources.map { .init(url: $0.url.absoluteString, name: $0.name) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    /// One address per line, nothing else, so it pastes into anything.
    public static func exportText(_ sources: [CatalogSource]) -> String {
        sources.map { $0.url.absoluteString + "\n" }.joined()
    }

    // MARK: Reading

    /// Reads at most `maxBytes` from a file, and refuses a larger one without loading it.
    public static func read(contentsOf url: URL) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try bounded(handle)
        } catch let error as SourceListError {
            throw error
        } catch {
            throw SourceListError.unreadable(error.localizedDescription)
        }
    }

    /// For standard input, with the same bound.
    public static func read(from handle: FileHandle) throws -> Data {
        do {
            return try bounded(handle)
        } catch let error as SourceListError {
            throw error
        } catch {
            throw SourceListError.unreadable(error.localizedDescription)
        }
    }

    private static func bounded(_ handle: FileHandle) throws -> Data {
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw SourceListError.tooLarge(limit: maxBytes) }
        return data
    }

    // MARK: Parsing

    /// Accepts the Eider JSON file, a JSON array of address strings or of objects
    /// with a `url`, or plain text with one address (or `eider://source/` link)
    /// per line, where blank lines and lines starting with "#" are ignored.
    public static func parse(_ data: Data) throws -> ParsedSourceList {
        guard data.count <= maxBytes else { throw SourceListError.tooLarge(limit: maxBytes) }
        guard var text = String(data: data, encoding: .utf8) else { throw SourceListError.notText }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [Candidate]
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            candidates = try jsonCandidates(Data(trimmed.utf8))
        } else {
            candidates = textCandidates(trimmed)
        }
        guard !candidates.isEmpty else { throw SourceListError.noEntries }
        guard candidates.count <= maxEntries else { throw SourceListError.tooManyEntries(limit: maxEntries) }
        return resolve(candidates)
    }

    /// One entry as the file wrote it: text to resolve, or an element that was not text at all.
    private enum Candidate {
        case text(String)
        case malformed
    }

    private static func textCandidates(_ text: String) -> [Candidate] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map(Candidate.text)
    }

    private static func jsonCandidates(_ data: Data) throws -> [Candidate] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SourceListError.unreadable("it looks like JSON but does not parse.")
        }
        if let array = root as? [Any] { return array.map(jsonCandidate) }
        guard let object = root as? [String: Any] else {
            throw SourceListError.unreadable("expected a JSON array or an Eider sources file.")
        }
        if let format = object["format"] as? String, format != jsonFormat {
            throw SourceListError.unsupported("That file is a \"\(format)\" file, not an Eider sources file.")
        }
        if let version = object["version"] as? Int, version > jsonVersion {
            throw SourceListError.unsupported(
                "That sources file is version \(version); this Eider reads version \(jsonVersion). Update Eider and try again.")
        }
        guard let entries = object["sources"] as? [Any] else {
            throw SourceListError.unreadable("no \"sources\" list.")
        }
        return entries.map(jsonCandidate)
    }

    private static func jsonCandidate(_ element: Any) -> Candidate {
        if let text = element as? String { return .text(text) }
        if let object = element as? [String: Any], let text = object["url"] as? String { return .text(text) }
        return .malformed
    }

    private static func resolve(_ candidates: [Candidate]) -> ParsedSourceList {
        var urls: [URL] = []
        var seen = Set<URL>()
        var repeated: [URL] = []
        var rejected: [SourceListRejection] = []
        for candidate in candidates {
            switch candidate {
            case .malformed:
                rejected.append(.init(url: "(entry)", reason: "neither an address nor an object with a \"url\""))
            case .text(let raw):
                switch address(in: raw) {
                case .failure(let problem):
                    rejected.append(.init(url: shown(raw), reason: problem.reason))
                case .success(let url):
                    if seen.insert(url).inserted { urls.append(url) } else { repeated.append(url) }
                }
            }
        }
        return ParsedSourceList(urls: urls, repeated: repeated, rejected: rejected)
    }

    private struct Problem: Error { let reason: String }

    /// The same checks as a source typed into the app, with two stricter rules: a list comes
    /// from somebody else, so it may not point Eider at a file or a service on this Mac.
    /// An `eider://source/` link is unwrapped by `DeepLink`, so its rules are not repeated here.
    private static func address(in raw: String) -> Result<URL, Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= maxAddressLength else { return .failure(Problem(reason: "the address is too long")) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            return .failure(Problem(reason: "not a web address"))
        }
        if scheme == "eider" {
            switch DeepLink.parse(url) {
            case .addSource(let inner): return .success(inner)
            case .install: return .failure(Problem(reason: "an install link, not a source"))
            case nil: return .failure(Problem(reason: "not a usable Eider source link (the address inside must be https)"))
            }
        }
        if URLPolicy.isAllowed(url) { return .success(url) }
        switch scheme {
        case "file": return .failure(Problem(reason: "a file on this Mac is not imported from a list; add it by hand"))
        case "http":
            return .failure(Problem(reason: URLPolicy.isLoopbackURL(url)
                ? "an address on this Mac is not imported from a list; add it by hand"
                : "only https addresses are allowed"))
        case "https": return .failure(Problem(reason: "the address has no host"))
        default: return .failure(Problem(reason: "only https addresses are allowed"))
        }
    }

    /// A rejected line is shown back to the person, so it is bounded and has no control characters.
    private static func shown(_ raw: String) -> String {
        let flattened = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }))
        return flattened.count > 200 ? String(flattened.prefix(200)) + "..." : flattened
    }

    // MARK: Importing

    /// Reads the list and adds every new address through `add`, at most
    /// `maxConcurrentFetches` at a time. One address failing is recorded and the rest go on.
    /// `onProgress` is told how many of the new addresses have finished.
    public static func importList(
        _ data: Data,
        existing: [URL],
        add: @escaping @Sendable (URL) async throws -> CatalogSource,
        onProgress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> SourceImportResult {
        let parsed = try parse(data)
        let known = Set(existing)
        let fresh = parsed.urls.filter { !known.contains($0) }
        var result = SourceImportResult(
            alreadyPresent: parsed.urls.filter(known.contains).map(\.absoluteString) + parsed.repeated.map(\.absoluteString),
            rejected: parsed.rejected)

        onProgress(0, fresh.count)
        let outcomes = await fetchAll(fresh, add: add, onProgress: onProgress)
        for (url, outcome) in zip(fresh, outcomes) {
            switch outcome {
            case nil: continue
            case .success?: result.added.append(url.absoluteString)
            case .failure(let error)?:
                let failure = error.codedFailure
                result.failed.append(.init(url: url.absoluteString, error: "\(failure.message) (\(failure.code))"))
            }
        }
        return result
    }

    /// A sliding window: a new fetch starts as each one finishes, so a slow
    /// source never holds up the ones behind it. Results come back in `urls`
    /// order; an address never started because the import was cancelled is nil.
    private static func fetchAll(
        _ urls: [URL],
        add: @escaping @Sendable (URL) async throws -> CatalogSource,
        onProgress: @Sendable (Int, Int) -> Void
    ) async -> [Result<Void, Error>?] {
        var outcomes = [Result<Void, Error>?](repeating: nil, count: urls.count)
        await withTaskGroup(of: (Int, Result<Void, Error>).self) { group in
            var next = 0
            func startNext() {
                guard next < urls.count else { return }
                let index = next, url = urls[next]
                next += 1
                group.addTask {
                    do { _ = try await add(url); return (index, .success(())) } catch { return (index, .failure(error)) }
                }
            }
            for _ in 0..<min(maxConcurrentFetches, urls.count) { startNext() }
            var done = 0
            for await (index, outcome) in group {
                outcomes[index] = outcome
                done += 1
                onProgress(done, urls.count)
                if !Task.isCancelled { startNext() }
            }
        }
        return outcomes
    }
}
