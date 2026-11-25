import Foundation

extension CatalogVersion {
    /// Is this release strictly newer than `other`? One rule for "newest" everywhere
    /// (the order of a merged `versions` list, the version an install takes, the
    /// update check): the version number decides (`AppVersion`: numeric beats a
    /// hash or a label, 1.10 beats 1.9); among numerically equal versions a
    /// build number decides when both carry one; the date breaks what is left,
    /// and a version with no date ranks below one with a date.
    ///
    /// The date is the last word and not the first because it is the least
    /// reliable field: in the 17,430-entry source this was written against,
    /// BlockerX 6.4.2 is dated 12 July and 6.5.3 is dated 25 May.
    func ranksAbove(_ other: CatalogVersion) -> Bool {
        let order = AppVersion.compare(version, other.version)
        if order != .orderedSame { return order == .orderedDescending }
        if AppVersion.isDottedNumeric(version), let build, let otherBuild = other.build,
           !build.isEmpty, !otherBuild.isEmpty {
            let buildOrder = AppVersion.compare(build, otherBuild)
            if buildOrder != .orderedSame { return buildOrder == .orderedDescending }
        }
        return (date ?? .distantPast) > (other.date ?? .distantPast)
    }
}

/// Sources in the wild list one app as several entries with the same bundle id
/// (one per version: 1Blocker ten times, in a 17,430-entry source). Browsing
/// every copy and identifying a row by "<source>|<bundle id>" made rows collide,
/// so entries that share a bundle id within one source become one app here.
/// Different sources stay separate: the owner chooses which one to trust.
enum CatalogMerge {
    /// The apps with entries sharing a bundle id merged, at the position of the
    /// first of them. An app listed once is returned untouched.
    static func merging(_ apps: [CatalogApp]) -> [CatalogApp] {
        var slot: [String: Int] = [:]
        var groups: [[CatalogApp]] = []
        for app in apps {
            if let index = slot[app.bundleID] {
                groups[index].append(app)
            } else {
                slot[app.bundleID] = groups.count
                groups.append([app])
            }
        }
        guard groups.count != apps.count else { return apps }
        return groups.map { $0.count == 1 ? $0[0] : merge($0) }
    }

    /// The source with its entries merged. `entryCount` records how many entries
    /// the document listed, but only when some were merged.
    static func normalized(_ source: CatalogSource) -> CatalogSource {
        let merged = merging(source.apps)
        guard merged.count != source.apps.count else { return source }
        var copy = source
        copy.apps = merged
        copy.entryCount = source.entryCount ?? source.apps.count
        return copy
    }

    /// App-level fields come from the entry that carries the newest version, and
    /// any field it leaves empty from the first entry that has one; each version
    /// keeps its own notes, size, date, hash and address.
    private static func merge(_ entries: [CatalogApp]) -> CatalogApp {
        var candidates: [(version: CatalogVersion, entry: Int)] = []
        for (index, entry) in entries.enumerated() {
            for version in entry.versions { candidates.append((version, index)) }
        }
        // Stable: equal versions keep source order.
        let ranked = candidates.enumerated()
            .sorted { left, right in
                if left.element.version.ranksAbove(right.element.version) { return true }
                if right.element.version.ranksAbove(left.element.version) { return false }
                return left.offset < right.offset
            }
            .map(\.element)

        var versions: [CatalogVersion] = []
        var position: [VersionKey: Int] = [:]
        for candidate in ranked {
            let key = VersionKey(version: candidate.version.version, url: candidate.version.downloadURL)
            if let existing = position[key] {
                versions[existing] = versions[existing].filling(from: candidate.version)
            } else {
                position[key] = versions.count
                versions.append(candidate.version)
            }
        }

        let primary = ranked.first?.entry ?? 0
        let order = [primary] + entries.indices.filter { $0 != primary }
        let ordered = order.map { entries[$0] }
        func first<Value>(_ field: (CatalogApp) -> Value?) -> Value? {
            for entry in ordered { if let value = field(entry) { return value } }
            return nil
        }
        func firstText(_ field: (CatalogApp) -> String?) -> String? {
            first { field($0).flatMap { $0.isEmpty ? nil : $0 } }
        }
        return CatalogApp(
            bundleID: entries[primary].bundleID,
            name: firstText({ $0.name }) ?? entries[primary].name,
            developerName: firstText(\.developerName),
            subtitle: firstText(\.subtitle),
            description: firstText(\.description),
            iconURL: first(\.iconURL),
            tintColor: firstText(\.tintColor),
            category: firstText(\.category),
            screenshots: first { $0.screenshots.isEmpty ? nil : $0.screenshots } ?? [],
            versions: versions
        )
    }

    private struct VersionKey: Hashable {
        let version: String
        let url: URL
    }
}

private extension CatalogVersion {
    /// The same release listed twice: keep this one, take what only the other has.
    func filling(from other: CatalogVersion) -> CatalogVersion {
        var copy = self
        copy.build = build ?? other.build
        copy.date = date ?? other.date
        copy.notes = notes ?? other.notes
        copy.size = size ?? other.size
        copy.minOSVersion = minOSVersion ?? other.minOSVersion
        copy.maxOSVersion = maxOSVersion ?? other.maxOSVersion
        copy.sha256 = sha256 ?? other.sha256
        return copy
    }
}
