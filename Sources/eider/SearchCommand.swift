import ArgumentParser
import EiderKit
import Foundation

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Find apps in your sources (all of them without a term).")

    @Argument(help: "Part of an app's name, bundle id, developer or subtitle.")
    var term: String?

    @OptionGroup var common: CommonOptions

    private struct Row: Encodable {
        let bundleID: String
        let name: String
        let developer: String?
        let version: String?
        let source: String
    }

    private struct Payload: Encodable { let apps: [Row] }

    func run() async throws {
        try await common.guarded { output in
            let found = try await AppOperations().sources.allApps()
                .filter { Self.matches($0.app, term) }
                .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
            let rows = found.map {
                Row(bundleID: $0.app.bundleID, name: $0.app.name, developer: $0.app.developerName,
                    version: UpdateChecker.newestVersion(of: $0.app)?.version, source: $0.source.name)
            }
            let text = rows.isEmpty
                ? "No apps found."
                : Table.render(["NAME", "BUNDLE ID", "VERSION", "SOURCE"], rows.map { [$0.name, $0.bundleID, $0.version ?? "-", $0.source] })
            output.result(Payload(apps: rows), text: text)
        }
    }

    static func matches(_ app: CatalogApp, _ term: String?) -> Bool {
        guard let term = term?.trimmingCharacters(in: .whitespaces), !term.isEmpty else { return true }
        return [app.name, app.bundleID, app.developerName, app.subtitle]
            .contains { $0?.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
