import Foundation

/// Search text and a source choice applied to the catalog. Pure, so the rule is
/// tested without a window.
public struct BrowseFilter: Equatable, Sendable {
    public var text = ""
    public var source: URL?

    public init(text: String = "", source: URL? = nil) {
        self.text = text
        self.source = source
    }

    public func apply(to apps: [SourcedApp]) -> [SourcedApp] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return apps
            .filter { source == nil || $0.sourceURL == source }
            .filter { entry in words.allSatisfy { matches(entry.app, word: $0) } }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    private func matches(_ app: CatalogApp, word: String) -> Bool {
        [app.name, app.bundleID, app.developerName, app.subtitle].contains {
            $0?.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

extension SourcedApp: Identifiable {
    /// The same bundle id in two sources is two rows.
    public var id: String { "\(source.url.absoluteString)|\(app.bundleID)" }
}

/// Where an app in Browse stands against the library.
public enum InstallStatus: Equatable, Sendable {
    case notInstalled
    case installed(version: String)
    case updateAvailable(from: String, to: String)
}

public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case library, browse, activity, sources
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
