import Foundation

/// The catalog flattened for Browse: sorted by name once, with the text a search
/// looks at folded (case and diacritics removed) once. Built off the main actor
/// when the catalog changes; a query then costs one substring search per word
/// per app instead of a locale-aware sort of the whole catalog.
final class BrowseIndex: Sendable {
    static let empty = BrowseIndex([])

    /// Between fields, so a word cannot match across the end of one and the
    /// start of the next. U+001F is not whitespace, so no typed word holds it.
    private static let fieldSeparator: Character = "\u{1F}"

    /// Sorted by name, case-insensitively and by the user's locale.
    let entries: [SourcedApp]
    /// Every entry by its `id`, whatever the filter shows.
    let byID: [String: SourcedApp]

    private let keys: [String]
    private let sourceSlot: [Int32]
    private let slotOfSource: [URL: Int32]

    init(_ catalog: [SourcedApp]) {
        // A stable sort, as the one it replaces was: equal names keep catalog order.
        let order = catalog.indices.sorted { lhs, rhs in
            switch catalog[lhs].app.name.localizedCaseInsensitiveCompare(catalog[rhs].app.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs < rhs
            }
        }
        var slots: [URL: Int32] = [:]
        var entries: [SourcedApp] = []
        var keys: [String] = []
        var sourceSlot: [Int32] = []
        entries.reserveCapacity(catalog.count)
        keys.reserveCapacity(catalog.count)
        sourceSlot.reserveCapacity(catalog.count)
        for index in order {
            let entry = catalog[index]
            entries.append(entry)
            keys.append(Self.key(for: entry.app))
            let url = entry.sourceURL
            let slot: Int32
            if let known = slots[url] {
                slot = known
            } else {
                slot = Int32(slots.count)
                slots[url] = slot
            }
            sourceSlot.append(slot)
        }
        // First in catalog order wins, as the linear search it replaces did.
        var byID: [String: SourcedApp] = [:]
        byID.reserveCapacity(catalog.count)
        for entry in catalog where byID[entry.id] == nil { byID[entry.id] = entry }
        self.entries = entries
        self.byID = byID
        self.keys = keys
        self.sourceSlot = sourceSlot
        self.slotOfSource = slots
    }

    /// The entries the filter lets through, in `entries` order. Every word must
    /// match the name, bundle id, developer or subtitle, ignoring case and accents.
    func results(for filter: BrowseFilter) -> [SourcedApp] {
        if filter.isUnfiltered { return entries }
        let words = filter.words.map(Self.fold)
        if words.contains(where: { $0.contains(Self.fieldSeparator) }) { return [] }
        var wantedSlot: Int32?
        if let source = filter.source {
            guard let slot = slotOfSource[source] else { return [] }
            wantedSlot = slot
        }
        var results: [SourcedApp] = []
        for index in entries.indices {
            if let wantedSlot, sourceSlot[index] != wantedSlot { continue }
            let key = keys[index]
            if words.allSatisfy({ key.range(of: $0, options: .literal) != nil }) {
                results.append(entries[index])
            }
        }
        return results
    }

    private static func key(for app: CatalogApp) -> String {
        [app.name, app.bundleID, app.developerName, app.subtitle]
            .map { fold($0 ?? "") }
            .joined(separator: String(fieldSeparator))
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
