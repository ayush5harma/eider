import ArgumentParser
import EiderKit
import Foundation

struct SourceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "source",
        abstract: "Add, list, remove and refresh sources.",
        subcommands: [SourceAddCommand.self, SourceListCommand.self, SourceRemoveCommand.self, SourceRefreshCommand.self]
    )
}

/// How a source is shown by every `source` command.
struct SourceSummary: Encodable {
    let url: String
    let name: String
    let format: String
    let apps: Int
    /// Entries the document listed, present only when some shared a bundle id and a name and were merged.
    let entries: Int?
    /// Saved by 0.1.2 to 0.1.6, which merged apps that only share a bundle id: some apps are
    /// missing until `eider source refresh`.
    let needsRefresh: Bool
    let fetchedAt: Date
    let warnings: [String]

    init(_ source: CatalogSource) {
        url = source.url.absoluteString
        name = source.name
        format = source.format.rawValue
        apps = source.apps.count
        entries = source.entryCount
        needsRefresh = source.isOverMerged
        fetchedAt = source.fetchedAt
        warnings = source.warnings
    }
}
