import Foundation

/// A newer version of an installed app that a source offers.
public struct AvailableUpdate: Codable, Sendable, Equatable, Identifiable {
    public var id: String { installed.bundleID }

    public let installed: InstalledApp
    /// The source the new version comes from.
    public let sourceURL: URL
    /// That source's name, for the Updates list and `eider list`.
    public let sourceName: String
    /// The entry offering it, as the source lists it: `app.bundleID` is the
    /// listed id, which may differ from `installed.bundleID` (see InstallOrigin).
    public let app: CatalogApp
    public let version: CatalogVersion

    public init(installed: InstalledApp, sourceURL: URL, sourceName: String = "", app: CatalogApp, version: CatalogVersion) {
        self.installed = installed
        self.sourceURL = sourceURL
        self.sourceName = sourceName
        self.app = app
        self.version = version
    }

    /// Where an update installed from here comes from.
    public var origin: InstallOrigin { InstallOrigin(sourceURL: sourceURL, entryID: app.bundleID) }
}

/// Compares what is installed with what the sources offer. Pure: the caller
/// passes both lists, so the CLI, the app and the tests all use one rule.
public enum UpdateChecker {
    /// One entry per installed app that has a newer version in the catalog, in
    /// the order of `installed`.
    ///
    /// The candidates for an app are, in order of preference:
    /// 1. the entry it was installed from (`origin`), when that source is still
    ///    added and still lists the entry: the only way to match an entry whose
    ///    listed id differs from the IPA's real one;
    /// 2. for an entry written before origins existed, the entries with its
    ///    bundle id in the source it recorded (`sourceURL`), as before;
    /// 3. otherwise every entry with its bundle id, in any source.
    /// Another source's higher number is the owner's call to take, not an
    /// update, so a known origin is never widened. The offer is the candidate
    /// version that ranks highest (`CatalogVersion.ranksAbove`), and only when it
    /// ranks above the installed version: a hash or a label never does.
    public static func updates(installed: [InstalledApp], catalog: [SourcedApp]) -> [AvailableUpdate] {
        // One pass over the catalog, not one per installed app: a 17k-app source
        // times a full library was the cost. Grouping keeps catalog order per id.
        let index = Index(catalog)
        return installed.compactMap { update(for: $0, candidates: index.candidates(for: $0)) }
    }

    public static func update(for app: InstalledApp, in catalog: [SourcedApp]) -> AvailableUpdate? {
        update(for: app, candidates: Index(catalog).candidates(for: app))
    }

    /// Whether any source lists the app at all, by origin or by bundle id.
    public static func isListed(_ app: InstalledApp, in catalog: [SourcedApp]) -> Bool {
        !Index(catalog).candidates(for: app).isEmpty
    }

    private struct Index {
        struct Key: Hashable {
            let sourceURL: URL
            let entryID: String
        }

        let byID: [String: [SourcedApp]]
        let byEntry: [Key: SourcedApp]

        init(_ catalog: [SourcedApp]) {
            byID = Dictionary(grouping: catalog, by: \.app.bundleID)
            byEntry = Dictionary(
                catalog.map { (Key(sourceURL: $0.sourceURL, entryID: $0.app.bundleID), $0) }, uniquingKeysWith: { first, _ in first })
        }

        func candidates(for app: InstalledApp) -> [SourcedApp] {
            if let origin = app.origin, let entry = byEntry[Key(sourceURL: origin.sourceURL, entryID: origin.entryID)] {
                return [entry]
            }
            let sameID = byID[app.bundleID] ?? []
            if app.origin == nil, let recorded = app.sourceURL {
                let fromRecorded = sameID.filter { $0.sourceURL == recorded }
                if !fromRecorded.isEmpty { return fromRecorded }
            }
            return sameID
        }
    }

    private static func update(for app: InstalledApp, candidates: [SourcedApp]) -> AvailableUpdate? {
        var best: (sourced: SourcedApp, version: CatalogVersion)?
        for sourced in candidates {
            guard let newest = newestVersion(of: sourced.app) else { continue }
            if let current = best, !newest.ranksAbove(current.version) { continue }
            best = (sourced, newest)
        }
        guard let best, AppVersion.isNewer(version: best.version.version, build: best.version.build, than: app.version, build: app.build) else {
            return nil
        }
        return AvailableUpdate(
            installed: app, sourceURL: best.sourced.sourceURL, sourceName: best.sourced.source.name,
            app: best.sourced.app, version: best.version)
    }

    /// Does not trust the order a source lists versions in.
    public static func newestVersion(of app: CatalogApp) -> CatalogVersion? {
        app.versions.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return candidate.ranksAbove(best) ? candidate : best
        }
    }
}
