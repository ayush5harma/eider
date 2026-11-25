import Foundation

/// A newer version of an installed app that a source offers.
public struct AvailableUpdate: Codable, Sendable, Equatable, Identifiable {
    public var id: String { installed.bundleID }

    public let installed: InstalledApp
    /// The source the new version comes from.
    public let sourceURL: URL
    public let app: CatalogApp
    public let version: CatalogVersion

    public init(installed: InstalledApp, sourceURL: URL, app: CatalogApp, version: CatalogVersion) {
        self.installed = installed
        self.sourceURL = sourceURL
        self.app = app
        self.version = version
    }
}

/// Compares what is installed with what the sources offer. Pure: the caller
/// passes both lists, so the CLI, the app and the tests all use one rule.
public enum UpdateChecker {
    /// One entry per installed app that has a newer version in the catalog, in
    /// the order of `installed`.
    ///
    /// Matching is by bundle id. An app installed from a source that still lists
    /// it is compared with that source only: another source's higher number is
    /// the owner's call to take, not an update. When the origin is unknown or
    /// gone, the newest version across all sources counts.
    public static func updates(installed: [InstalledApp], catalog: [SourcedApp]) -> [AvailableUpdate] {
        // One pass over the catalog, not one per installed app: a 17k-app source
        // times a full library was the cost. Grouping keeps catalog order per id.
        let byID = Dictionary(grouping: catalog, by: \.app.bundleID)
        return installed.compactMap { update(for: $0, candidates: byID[$0.bundleID] ?? []) }
    }

    public static func update(for app: InstalledApp, in catalog: [SourcedApp]) -> AvailableUpdate? {
        update(for: app, candidates: catalog.filter { $0.app.bundleID == app.bundleID })
    }

    /// `candidates` are the catalog entries with the app's bundle id, in catalog order.
    private static func update(for app: InstalledApp, candidates: [SourcedApp]) -> AvailableUpdate? {
        let fromOrigin = candidates.filter { $0.sourceURL == app.sourceURL }
        let pool = fromOrigin.isEmpty ? candidates : fromOrigin

        var best: (sourced: SourcedApp, version: CatalogVersion)?
        for sourced in pool {
            guard let newest = newestVersion(of: sourced.app) else { continue }
            if let current = best, !isNewer(newest, than: current.version) { continue }
            best = (sourced, newest)
        }
        guard let best, AppVersion.isNewer(version: best.version.version, build: best.version.build, than: app.version, build: app.build) else {
            return nil
        }
        return AvailableUpdate(installed: app, sourceURL: best.sourced.sourceURL, app: best.sourced.app, version: best.version)
    }

    /// Does not trust the order a source lists versions in.
    public static func newestVersion(of app: CatalogApp) -> CatalogVersion? {
        app.versions.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return isNewer(candidate, than: best) ? candidate : best
        }
    }

    private static func isNewer(_ lhs: CatalogVersion, than rhs: CatalogVersion) -> Bool {
        lhs.ranksAbove(rhs)
    }
}
