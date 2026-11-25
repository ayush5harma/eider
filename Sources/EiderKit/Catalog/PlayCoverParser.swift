import Foundation

/// PlayCover source lists: `[{bundleID, name, version, itunesLookup, link, checksum?}]`,
/// bare or wrapped as `{name, data: [...], id?}`. `itunesLookup` is never fetched.
enum PlayCoverParser {
    static func parse(
        list: [Any], wrapper: JSONDict, context: inout ParseContext, now: Date
    ) throws -> CatalogSource {
        var apps: [CatalogApp] = []
        for (index, element) in list.enumerated() {
            guard let item = element as? JSONDict else {
                context.warn("entry #\(index + 1): not an object, skipped")
                continue
            }
            if let app = parseApp(item, index: index + 1, context: &context) {
                apps.append(app)
            }
        }
        guard !apps.isEmpty else { throw CatalogFailure.noUsableApps(warnings: context.warnings) }

        return CatalogSource(
            url: context.sourceURL,
            format: .playCover,
            name: wrapper.displayName("name") ?? context.fallbackName,
            identifier: wrapper.displayName("id"),
            apps: apps,
            warnings: context.warnings,
            fetchedAt: now
        )
    }

    private static func parseApp(_ item: JSONDict, index: Int, context: inout ParseContext) -> CatalogApp? {
        // The id is the source's label for the app, kept as given (see CatalogIdentifier).
        let bundleID = CatalogIdentifier.cleaned(item.string("bundleID", "bundleId"))
        let name = item.displayName("name") ?? (item.string("name") != nil ? bundleID : nil)
        let label = { "entry #\(index) (\(bundleID.map(CatalogIdentifier.quoted) ?? name ?? "unnamed"))" }
        guard let bundleID else {
            context.warn("\(label()): no bundle id, skipped")
            return nil
        }
        guard !CatalogIdentifier.isTooLong(bundleID) else {
            context.warn("\(label()): bundle id longer than \(CatalogIdentifier.maxBytes) bytes, skipped")
            return nil
        }
        guard let name else {
            context.warn("\(label()): no name, skipped")
            return nil
        }
        guard let version = item.displayName("version") else {
            context.warn("\(label()): no version, skipped")
            return nil
        }
        guard let link = context.downloadURL(item.string("link"), label: label) else {
            if item.string("link") == nil { context.warn("\(label()): no download link, skipped") }
            return nil
        }
        let sha256 = checksum(item.string("checksum"), label: label, context: &context)
        let release = CatalogVersion(version: version, downloadURL: link, sha256: sha256)
        return CatalogApp(bundleID: bundleID, name: name, versions: [release])
    }

    /// A checksum is only trusted as a SHA-256 when it is 64 hex characters:
    /// PlayCover lists in the wild carry other digests in the same field.
    private static func checksum(_ raw: String?, label: () -> String, context: inout ParseContext) -> String? {
        guard let raw else { return nil }
        if let hash = LenientJSON.sha256(raw) { return hash }
        context.warn("\(label()): checksum is not a SHA-256, ignored")
        return nil
    }
}
