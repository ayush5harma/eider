import Foundation

/// Search text and a source choice. Applying it to a catalog is
/// `BrowseIndex.results(for:)`, which works from keys folded once per catalog.
public struct BrowseFilter: Equatable, Sendable {
    public var text = ""
    public var source: URL?

    public init(text: String = "", source: URL? = nil) {
        self.text = text
        self.source = source
    }

    /// Every word must match some field of an app.
    var words: [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// No words and no source: the whole catalog, already in order.
    var isUnfiltered: Bool {
        source == nil && text.allSatisfy(\.isWhitespace)
    }
}

extension SourcedApp: Identifiable {}

extension CatalogSource: Identifiable {
    public var id: URL { url }
}

/// Where an app in Browse stands against the library.
public enum InstallStatus: Equatable, Sendable {
    case notInstalled
    case installed(version: String)
    case updateAvailable(from: String, to: String)
}

public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case library, updates, browse, activity, sources
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
