import Foundation

/// AltStore-format sources, written from the published format description.
enum AltStoreParser {
    static func parse(root: JSONDict, context: inout ParseContext, now: Date) throws -> CatalogSource {
        var apps: [CatalogApp] = []
        for (index, element) in (root.array("apps") ?? []).enumerated() {
            guard let item = element as? JSONDict else {
                context.warn("app #\(index + 1): not an object, skipped")
                continue
            }
            if let app = parseApp(item, index: index + 1, context: &context) {
                apps.append(app)
            }
        }
        guard !apps.isEmpty else { throw CatalogFailure.noUsableApps(warnings: context.warnings) }

        let news = parseNews(root.array("news") ?? [], context: &context)
        return CatalogSource(
            url: context.sourceURL,
            format: .altStore,
            name: root.string("name") ?? context.fallbackName,
            identifier: root.string("identifier"),
            subtitle: root.string("subtitle"),
            description: root.string("description"),
            iconURL: context.url(root.string("iconURL")),
            headerURL: context.url(root.string("headerURL")),
            website: context.url(root.string("website")),
            tintColor: root.string("tintColor"),
            apps: apps,
            news: news,
            warnings: context.warnings,
            fetchedAt: now
        )
    }

    // MARK: Apps

    private static func parseApp(_ item: JSONDict, index: Int, context: inout ParseContext) -> CatalogApp? {
        let name = item.string("name")
        let bundleID = item.string("bundleIdentifier")
        let label = "app #\(index) (\(bundleID ?? name ?? "unnamed"))"
        guard let bundleID else {
            context.warn("\(label): no bundle identifier, skipped")
            return nil
        }
        guard let name else {
            context.warn("\(label): no name, skipped")
            return nil
        }
        let versions = parseVersions(of: item, label: label, context: &context)
        guard !versions.isEmpty else {
            context.warn("\(label): no downloadable version, skipped")
            return nil
        }
        return CatalogApp(
            bundleID: bundleID,
            name: name,
            developerName: item.string("developerName"),
            subtitle: item.string("subtitle"),
            description: item.string("localizedDescription"),
            iconURL: context.url(item.string("iconURL")),
            tintColor: item.string("tintColor"),
            category: item.string("category"),
            screenshots: screenshots(of: item, context: context),
            versions: versions
        )
    }

    private static func parseVersions(of app: JSONDict, label: String, context: inout ParseContext) -> [CatalogVersion] {
        var versions: [CatalogVersion] = []
        for (index, element) in (app.array("versions") ?? []).enumerated() {
            guard let entry = element as? JSONDict else { continue }
            if let version = parseVersion(entry, flat: false, label: "\(label) version #\(index + 1)", context: &context) {
                versions.append(version)
            }
        }
        // The flat form predates `versions`; some sources still ship it alone.
        if versions.isEmpty, let version = parseVersion(app, flat: true, label: label, context: &context) {
            versions.append(version)
        }
        return newestFirst(versions)
    }

    private static func parseVersion(
        _ entry: JSONDict, flat: Bool, label: String, context: inout ParseContext
    ) -> CatalogVersion? {
        guard let download = context.downloadURL(entry.string("downloadURL"), label: label) else { return nil }
        guard let number = entry.string("version", "marketingVersion") else {
            context.warn("\(label): no version number, skipped")
            return nil
        }
        var sha256: String?
        if let raw = entry.string("sha256") {
            sha256 = LenientJSON.sha256(raw)
            if sha256 == nil { context.warn("\(label): sha256 is not 64 hex characters, ignored") }
        }
        return CatalogVersion(
            version: number,
            build: entry.string("buildVersion"),
            date: context.dates.parse(flat ? entry["versionDate"] : entry["date"]),
            notes: flat ? entry.string("versionDescription") : entry.string("localizedDescription"),
            downloadURL: download,
            size: entry.int64("size").flatMap { $0 > 0 ? $0 : nil },
            minOSVersion: entry.string("minOSVersion"),
            maxOSVersion: entry.string("maxOSVersion"),
            sha256: sha256
        )
    }

    /// Sources list newest first, so source order is kept unless every version
    /// carries a date, in which case the dates decide (ties keep source order).
    private static func newestFirst(_ versions: [CatalogVersion]) -> [CatalogVersion] {
        guard versions.count > 1, versions.allSatisfy({ $0.date != nil }) else { return versions }
        return versions.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.date ?? .distantPast, rhs.element.date ?? .distantPast)
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
    }

    // MARK: Screenshots

    /// `screenshots` is an array of strings, an array of `{imageURL, ...}`, or
    /// an object keyed by device holding either; `screenshotURLs` is the older
    /// array of strings. All are flattened, in that order, without repeats.
    private static func screenshots(of app: JSONDict, context: ParseContext) -> [URL] {
        let raw = screenshotStrings(app["screenshots"]) + screenshotStrings(app["screenshotURLs"])
        var seen = Set<URL>()
        return raw.compactMap { context.url($0) }.filter { seen.insert($0).inserted }
    }

    private static func screenshotStrings(_ value: Any?) -> [String] {
        switch value {
        case let list as [Any]:
            return list.flatMap { element -> [String] in
                if let text = element as? String { return [text] }
                guard let object = element as? JSONDict else { return [] }
                return [object.string("imageURL", "url", "image")].compactMap { $0 }
            }
        case let byDevice as JSONDict:
            let order = ["iphone": 0, "ipad": 1]
            let keys = byDevice.keys.sorted { (order[$0] ?? 2, $0) < (order[$1] ?? 2, $1) }
            return keys.flatMap { screenshotStrings(byDevice[$0]) }
        default:
            return []
        }
    }

    // MARK: News

    private static func parseNews(_ list: [Any], context: inout ParseContext) -> [CatalogNews] {
        var news: [CatalogNews] = []
        for (index, element) in list.enumerated() {
            guard let item = element as? JSONDict,
                  let identifier = item.string("identifier"), let title = item.string("title")
            else {
                context.warn("news #\(index + 1): needs an identifier and a title, skipped")
                continue
            }
            news.append(CatalogNews(
                identifier: identifier,
                title: title,
                caption: item.string("caption"),
                date: context.dates.parse(item["date"]),
                url: context.url(item.string("url")),
                imageURL: context.url(item.string("imageURL")),
                appID: item.string("appID"),
                tintColor: item.string("tintColor")
            ))
        }
        return news
    }
}
