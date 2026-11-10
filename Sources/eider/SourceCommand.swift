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
    let fetchedAt: Date
    let warnings: [String]

    init(_ source: CatalogSource) {
        url = source.url.absoluteString
        name = source.name
        format = source.format.rawValue
        apps = source.apps.count
        fetchedAt = source.fetchedAt
        warnings = source.warnings
    }
}
