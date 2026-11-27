import Foundation

public enum SourceFormat: String, Codable, Sendable, Hashable {
    case altStore
    case playCover
}

public struct CatalogVersion: Codable, Sendable, Hashable {
    public var version: String
    public var build: String?
    public var date: Date?
    public var notes: String?
    public var downloadURL: URL
    public var size: Int64?
    public var minOSVersion: String?
    public var maxOSVersion: String?
    /// Lower-case hex. Not part of the AltStore format; honoured when a source supplies it.
    public var sha256: String?

    public init(
        version: String, build: String? = nil, date: Date? = nil, notes: String? = nil,
        downloadURL: URL, size: Int64? = nil, minOSVersion: String? = nil,
        maxOSVersion: String? = nil, sha256: String? = nil
    ) {
        self.version = version
        self.build = build
        self.date = date
        self.notes = notes
        self.downloadURL = downloadURL
        self.size = size
        self.minOSVersion = minOSVersion
        self.maxOSVersion = maxOSVersion
        self.sha256 = sha256
    }
}

public struct CatalogApp: Codable, Sendable, Hashable {
    public var bundleID: String
    public var name: String
    public var developerName: String?
    public var subtitle: String?
    public var description: String?
    public var iconURL: URL?
    public var tintColor: String?
    public var category: String?
    public var screenshots: [URL]
    /// Newest first.
    public var versions: [CatalogVersion]

    public var latest: CatalogVersion? { versions.first }

    /// What makes two entries with one bundle id the same app: the name, trimmed,
    /// with runs of whitespace collapsed, ignoring case. Tweak sources list many
    /// different apps under one bundle id (`CatalogMerge`).
    public var nameKey: String { Self.nameKey(name) }

    public static func nameKey(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    public init(
        bundleID: String, name: String, developerName: String? = nil, subtitle: String? = nil,
        description: String? = nil, iconURL: URL? = nil, tintColor: String? = nil,
        category: String? = nil, screenshots: [URL] = [], versions: [CatalogVersion]
    ) {
        self.bundleID = bundleID
        self.name = name
        self.developerName = developerName
        self.subtitle = subtitle
        self.description = description
        self.iconURL = iconURL
        self.tintColor = tintColor
        self.category = category
        self.screenshots = screenshots
        self.versions = versions
    }
}

public struct CatalogNews: Codable, Sendable, Hashable {
    public var identifier: String
    public var title: String
    public var caption: String?
    public var date: Date?
    public var url: URL?
    public var imageURL: URL?
    public var appID: String?
    public var tintColor: String?

    public init(
        identifier: String, title: String, caption: String? = nil, date: Date? = nil,
        url: URL? = nil, imageURL: URL? = nil, appID: String? = nil, tintColor: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.caption = caption
        self.date = date
        self.url = url
        self.imageURL = imageURL
        self.appID = appID
        self.tintColor = tintColor
    }
}

public struct CatalogSource: Codable, Sendable, Hashable {
    public var url: URL
    public var format: SourceFormat
    public var name: String
    public var identifier: String?
    public var subtitle: String?
    public var description: String?
    public var iconURL: URL?
    public var headerURL: URL?
    public var website: URL?
    public var tintColor: String?
    public var apps: [CatalogApp]
    public var news: [CatalogNews]
    /// One line per entry skipped or value ignored while parsing.
    public var warnings: [String]
    public var fetchedAt: Date
    /// How many app entries the document listed, set only when entries sharing a
    /// bundle id were merged into one app (so `apps.count` is smaller); nil when
    /// nothing was merged or the copy predates merging.
    public var entryCount: Int?
    /// The `CatalogMerge.rule` this copy was merged with; nil for a copy saved by
    /// 0.1.2 to 0.1.6, which merged every entry sharing a bundle id.
    public var mergeRule: Int?

    /// Whether this saved copy predates the current merge rule. The app's launch
    /// check refetches such a source at once instead of waiting for it to age.
    public var isOverMerged: Bool { mergeRule != CatalogMerge.rule }

    public init(
        url: URL, format: SourceFormat, name: String, identifier: String? = nil,
        subtitle: String? = nil, description: String? = nil, iconURL: URL? = nil,
        headerURL: URL? = nil, website: URL? = nil, tintColor: String? = nil,
        apps: [CatalogApp] = [], news: [CatalogNews] = [], warnings: [String] = [],
        fetchedAt: Date = Date(), entryCount: Int? = nil, mergeRule: Int? = nil
    ) {
        self.entryCount = entryCount
        self.mergeRule = mergeRule
        self.url = url
        self.format = format
        self.name = name
        self.identifier = identifier
        self.subtitle = subtitle
        self.description = description
        self.iconURL = iconURL
        self.headerURL = headerURL
        self.website = website
        self.tintColor = tintColor
        self.apps = apps
        self.news = news
        self.warnings = warnings
        self.fetchedAt = fetchedAt
    }
}

/// An app together with the source it came from. The same bundle id in two
/// sources is two entries: the owner chooses which source to trust.
public struct SourcedApp: Sendable, Hashable {
    public let source: CatalogSource
    public let app: CatalogApp
    /// Built once here: it was a computed string, so every comparison, every
    /// selection lookup and every List diff over a 17,000-app catalog allocated one.
    public let id: String

    public var sourceURL: URL { source.url }

    /// The id of an app that is the only one its source lists under its bundle
    /// id: "<source url>|<bundle id>". Use `entries(of:)` for a whole source,
    /// which tells these from the ones that need the name too.
    public init(source: CatalogSource, app: CatalogApp) {
        self.init(source: source, app: app, id: "\(source.url.absoluteString)|\(app.bundleID)")
    }

    init(source: CatalogSource, app: CatalogApp, id: String) {
        self.source = source
        self.app = app
        self.id = id
    }

    /// Every app of a source with its row id. An id is "<source url>|<bundle id>"
    /// while the source lists one name under that bundle id (so ids and selections
    /// made before names mattered survive), and "<source url>|<bundle id>|<name>"
    /// (`CatalogApp.nameKey`) once it lists several: one bundle id is then several
    /// apps (`CatalogMerge`), each its own row.
    public static func entries(of source: CatalogSource) -> [SourcedApp] {
        var firstName: [String: String] = [:]
        var shared = Set<String>()
        for app in source.apps {
            let name = app.nameKey
            if let seen = firstName[app.bundleID] {
                if seen != name { shared.insert(app.bundleID) }
            } else {
                firstName[app.bundleID] = name
            }
        }
        let base = source.url.absoluteString
        return source.apps.map { app in
            let id = shared.contains(app.bundleID)
                ? "\(base)|\(app.bundleID)|\(app.nameKey)" : "\(base)|\(app.bundleID)"
            return SourcedApp(source: source, app: app, id: id)
        }
    }
}
