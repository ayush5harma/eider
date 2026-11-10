import Foundation

/// State shared by the format parsers: where the document came from, how to
/// resolve and vet its URLs, and the warnings collected on the way.
struct ParseContext {
    let sourceURL: URL
    let dates = LenientDates()
    private(set) var warnings: [String] = []

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    /// A local source may point at local files; a remote one never may.
    var allowFile: Bool { sourceURL.isFileURL }

    /// Only a source the user added by a loopback address may point at loopback.
    var allowLoopback: Bool { URLPolicy.isLoopbackURL(sourceURL) }

    mutating func warn(_ line: String) {
        warnings.append(line)
    }

    /// Cosmetic URLs (icons, screenshots, links) are dropped without a warning.
    func url(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        return URLPolicy.resolve(raw, against: sourceURL, allowFile: allowFile, allowLoopback: allowLoopback)
    }

    /// A download URL that is present but refused deserves a line, because it
    /// is the reason an app disappears.
    mutating func downloadURL(_ raw: String?, label: String) -> URL? {
        guard let raw else { return nil }
        if let url = url(raw) { return url }
        warn("\(label): download address not allowed or not valid (\(raw))")
        return nil
    }

    /// Falls back to the host so a source with no name still has a label.
    var fallbackName: String {
        if let host = sourceURL.host, !host.isEmpty { return host }
        let last = sourceURL.deletingPathExtension().lastPathComponent
        return last.isEmpty ? sourceURL.absoluteString : last
    }
}
