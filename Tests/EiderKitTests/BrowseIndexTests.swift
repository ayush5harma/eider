import Foundation
import XCTest
@testable import EiderKit

/// The implementation Browse used before the index: filter, then sort the whole
/// catalog with a locale-aware compare, matching each word with `range(of:)`.
/// Kept here as the oracle the index must agree with.
enum OldBrowseFilter {
    static func apply(_ filter: BrowseFilter, to apps: [SourcedApp]) -> [SourcedApp] {
        let words = filter.text.split(whereSeparator: \.isWhitespace).map(String.init)
        return apps
            .filter { filter.source == nil || $0.sourceURL == filter.source }
            .filter { entry in words.allSatisfy { matches(entry.app, word: $0) } }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    private static func matches(_ app: CatalogApp, word: String) -> Bool {
        [app.name, app.bundleID, app.developerName, app.subtitle].contains {
            $0?.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

enum BrowseFixtures {
    static let sourceA = URL(string: "https://a.example.com/source.json")!
    static let sourceB = URL(string: "https://b.example.com/source.json")!

    static func source(_ url: URL, name: String) -> CatalogSource {
        CatalogSource(url: url, format: .altStore, name: name)
    }

    static func entry(
        _ source: CatalogSource, _ bundleID: String, _ name: String,
        developer: String? = nil, subtitle: String? = nil
    ) -> SourcedApp {
        let version = CatalogVersion(version: "1", downloadURL: URL(string: "https://cdn.example.com/\(bundleID).ipa")!)
        return SourcedApp(
            source: source,
            app: CatalogApp(bundleID: bundleID, name: name, developerName: developer, subtitle: subtitle, versions: [version]))
    }

    /// Accents, case, CJK, sharp s, Turkish dotted capital I, emoji, empty and
    /// missing fields, equal names, the same bundle id in two sources, and
    /// words that only meet across the end of one field and the start of the next.
    static func varied() -> [SourcedApp] {
        let a = source(sourceA, name: "A")
        let b = source(sourceB, name: "B")
        return [
            entry(a, "org.alpha", "Alpha Café", developer: "Beta Works"),
            entry(a, "com.zeta.app", "Zeta Notes", developer: "Acme Studio", subtitle: "Quick notes"),
            entry(a, "com.same.one", "Same"),
            entry(a, "com.same.two", "same", developer: "Other"),
            entry(b, "com.same.three", "SAME", subtitle: "third"),
            entry(a, "de.strasse", "Straße", developer: "Müller GmbH"),
            entry(b, "tr.istanbul", "İstanbul Guide", developer: "Şükrü"),
            entry(a, "jp.nihon", "日本語 Reader", developer: "山田", subtitle: "辞書"),
            entry(b, "emoji.app", "Rocket 🚀", subtitle: "to the moon"),
            entry(a, "com.shared", "Shared", developer: "Dev"),
            entry(b, "com.shared", "Shared", developer: "Dev"),
            entry(a, "com.edge.one", "Alpha", developer: "Beta"),
            entry(a, "com.empty", "", developer: "", subtitle: ""),
            entry(a, "com.accent.nfd", "Cafe\u{301} Deux"),
            entry(b, "COM.UPPER", "Upper", developer: "ÉCOLE"),
            entry(a, "com.digits", "2048 Puzzle"),
            entry(a, "com.digits2", "10 Pins"),
            entry(b, "com.punct", "_Under Score"),
            entry(a, "com.punct2", "-Dash"),
            entry(a, "com.words", "Zeta Alpha Notes", developer: "Studio"),
        ]
    }

    static let queries = [
        "", "   ", "alpha", "ALPHA", "cafe", "CAFÉ", "café", "cafe deux", "deux", "beta works", "works beta",
        "alphabeta", "betaworks", "zeta notes", "studio acme", "acme  studio", "quick", "notes quick",
        "strasse", "straße", "muller", "müller", "mueller", "istanbul", "ISTANBUL", "İstanbul", "sukru", "ş",
        "日本", "日本語", "山田", "辞書", "reader 辞書", "rocket", "🚀", "moon", "org.", "com.", ".", "same", "SAME", "sam e",
        "shared", "com.shared", "ecole", "école", "upper", "com.upper", "2048", "pins", "under", "_", "-dash",
        "nothing like this", "z", "e", "a b", "\u{1F}",
    ]
}

final class BrowseIndexTests: XCTestCase {
    private func assertAgrees(_ catalog: [SourcedApp], filters: [BrowseFilter], file: StaticString = #filePath, line: UInt = #line) {
        let index = BrowseIndex(catalog)
        for filter in filters {
            let expected = OldBrowseFilter.apply(filter, to: catalog).map(\.id)
            let actual = index.results(for: filter).map(\.id)
            XCTAssertEqual(actual, expected, "text \(filter.text.debugDescription) source \(String(describing: filter.source))", file: file, line: line)
        }
    }

    func testResultsAgreeWithTheOldImplementationOnAVariedFixtureForEveryQueryAndSource() {
        let catalog = BrowseFixtures.varied()
        let filters = BrowseFixtures.queries.flatMap { text in
            [nil, BrowseFixtures.sourceA, BrowseFixtures.sourceB].map { BrowseFilter(text: text, source: $0) }
        }
        assertAgrees(catalog, filters: filters)
    }

    /// The one measured difference. The old range(of:, [.caseInsensitive,
    /// .diacriticInsensitive]) matched a lone "ß" against names holding no sharp s
    /// ("Same", "Shared", "Zeta Notes": ICU treats it as "ss" and then accepts a
    /// lone "s"). The folded search finds only the app that has one.
    func testALoneSharpSMatchesOnlyNamesHoldingOne() {
        let found = BrowseIndex(BrowseFixtures.varied()).results(for: BrowseFilter(text: "ß")).map(\.app.bundleID)
        XCTAssertEqual(found, ["de.strasse"])
    }

    func testAnAddressNoSourceHasGivesNoResults() {
        let index = BrowseIndex(BrowseFixtures.varied())
        XCTAssertTrue(index.results(for: BrowseFilter(source: URL(string: "https://nowhere.example.com/x.json")!)).isEmpty)
    }

    func testEqualNamesKeepCatalogOrderAsTheStableSortDid() {
        let catalog = BrowseFixtures.varied()
        let same = BrowseIndex(catalog).results(for: BrowseFilter(text: "same")).map(\.app.bundleID)
        XCTAssertEqual(same, ["com.same.one", "com.same.two", "com.same.three"])
    }

    func testAnUnfilteredQueryReturnsTheSortedBaseWithoutFiltering() {
        let catalog = BrowseFixtures.varied()
        let index = BrowseIndex(catalog)
        XCTAssertEqual(index.results(for: BrowseFilter()).map(\.id), index.entries.map(\.id))
        XCTAssertEqual(index.results(for: BrowseFilter(text: "  \t")).map(\.id), index.entries.map(\.id))
        XCTAssertEqual(index.entries.map(\.id), OldBrowseFilter.apply(BrowseFilter(), to: catalog).map(\.id))
    }

    func testEntryLookupByIDFindsEveryEntryAndTheFirstOfADuplicate() {
        let source = BrowseFixtures.source(BrowseFixtures.sourceA, name: "A")
        let first = BrowseFixtures.entry(source, "com.dup", "Zed")
        let second = BrowseFixtures.entry(source, "com.dup", "Aardvark")
        let index = BrowseIndex([first, second] + BrowseFixtures.varied())
        XCTAssertEqual(index.byID[first.id]?.app.name, "Zed", "the first in catalog order, as the linear search found")
        for entry in BrowseFixtures.varied() { XCTAssertNotNil(index.byID[entry.id]) }
    }

    func testSourcedAppIDKeepsItsFormatSoSavedSelectionsStillMatch() {
        let entry = BrowseFixtures.entry(BrowseFixtures.source(BrowseFixtures.sourceA, name: "A"), "com.x", "X")
        XCTAssertEqual(entry.id, "https://a.example.com/source.json|com.x")
    }

    func testWarningsLabelIsSingularForOne() {
        var source = BrowseFixtures.source(BrowseFixtures.sourceA, name: "A")
        source.warnings = ["one"]
        XCTAssertEqual(source.warningsLabel, "1 warning")
        source.warnings = ["one", "two"]
        XCTAssertEqual(source.warningsLabel, "2 warnings")
    }
}
