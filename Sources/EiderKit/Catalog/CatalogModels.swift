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

    public init(
        url: URL, format: SourceFormat, name: String, identifier: String? = nil,
        subtitle: String? = nil, description: String? = nil, iconURL: URL? = nil,
        headerURL: URL? = nil, website: URL? = nil, tintColor: String? = nil,
        apps: [CatalogApp] = [], news: [CatalogNews] = [], warnings: [String] = [],
        fetchedAt: Date = Date()
    ) {
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

    public var sourceURL: URL { source.url }
}
