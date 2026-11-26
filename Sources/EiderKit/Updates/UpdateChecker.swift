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
    public var origin: InstallOrigin { InstallOrigin(sourceURL: sourceURL, entryID: app.bundleID, entryName: app.name) }
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
    ///    listed id differs from the IPA's real one. The entry is the one with
    ///    the recorded id AND name: a tweak source lists many different apps
    ///    under one id (`CatalogMerge`), and YTKACE must not be offered
    ///    YouTubeOLED's version. An origin from before names were recorded
    ///    (0.1.4 to 0.1.6) takes the id's only entry, or else the one named
    ///    like the installed app;
    /// 2. for an entry written before origins existed, the entries with its
    ///    bundle id in the source it recorded (`sourceURL`), chosen the same way;
    /// 3. otherwise the entries with its bundle id in any source, but only in a
    ///    source that lists one name under that id: where several apps share it,
    ///    nothing says which of them this is, and a different app is not an update.
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
        /// Every entry a source lists under one id: several when they are different apps.
        let byEntry: [Key: [SourcedApp]]

        init(_ catalog: [SourcedApp]) {
            byID = Dictionary(grouping: catalog, by: \.app.bundleID)
            byEntry = Dictionary(grouping: catalog) { Key(sourceURL: $0.sourceURL, entryID: $0.app.bundleID) }
        }

        func candidates(for app: InstalledApp) -> [SourcedApp] {
            if let origin = app.origin {
                let exact = pick(byEntry[Key(sourceURL: origin.sourceURL, entryID: origin.entryID)] ?? [], name: origin.entryName, installedName: app.name)
                if !exact.isEmpty { return exact }
            } else if let recorded = app.sourceURL {
                let exact = pick(byEntry[Key(sourceURL: recorded, entryID: app.bundleID)] ?? [], name: nil, installedName: app.name)
                if !exact.isEmpty { return exact }
            }
            return (byID[app.bundleID] ?? []).filter(listsOneName)
        }

        /// The entries among `listed` (all under one id in one source) that are the app
        /// named `name`; with no name recorded, the only entry, or the one the installed
        /// app is named like.
        private func pick(_ listed: [SourcedApp], name: String?, installedName: String) -> [SourcedApp] {
            if let name {
                let key = CatalogApp.nameKey(name)
                return listed.filter { $0.app.nameKey == key }
            }
            if listed.count == 1 { return listed }
            let key = CatalogApp.nameKey(installedName)
            return listed.filter { $0.app.nameKey == key }
        }

        /// Whether the entry's source lists a single name under its id.
        private func listsOneName(_ entry: SourcedApp) -> Bool {
            let key = entry.app.nameKey
            return (byEntry[Key(sourceURL: entry.sourceURL, entryID: entry.app.bundleID)] ?? []).allSatisfy { $0.app.nameKey == key }
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
