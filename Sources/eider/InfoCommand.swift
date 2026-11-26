import ArgumentParser
import EiderKit
import Foundation

struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show what a source offers for an app, and whether it is installed.")

    @Argument(help: "The app's bundle id, or its full entry id when several apps share the bundle id.")
    var bundleID: String

    @OptionGroup var common: CommonOptions

    private struct Payload: Encodable {
        let app: CatalogApp
        let source: String
        let installed: InstalledApp?
    }

    /// Only looked up: in the sources by their own id, and in the library, whose
    /// entries are all strictly valid ids, by string comparison.
    func validate() throws { try requireCatalogID(bundleID) }

    func run() async throws {
        try await common.guarded { output in
            let operations = AppOperations()
            guard let entry = try await operations.catalogEntry(matching: bundleID) else {
                throw output.fail(FailureReport(code: "operations.not_in_catalog", message: "None of your sources lists \(bundleID)."))
            }
            let installed = try await operations.library.app(bundleID: entry.app.bundleID)
            output.result(Payload(app: entry.app, source: entry.sourceURL.absoluteString, installed: installed), text: Self.text(entry, installed))
        }
    }

    private static func text(_ entry: SourcedApp, _ installed: InstalledApp?) -> String {
        let app = entry.app
        var lines = [
            "\(app.name) (\(app.bundleID))",
            "Source:     \(entry.source.name) (\(entry.sourceURL.absoluteString))",
        ]
        if let developer = app.developerName { lines.append("Developer:  \(developer)") }
        if let subtitle = app.subtitle { lines.append("About:      \(subtitle)") }
        if let installed { lines.append("Installed:  \(installed.version) (\(installed.build)) at \(installed.path.path)") }
        lines.append("Versions:   " + (app.versions.map(\.version).joined(separator: ", ")))
        if let notes = app.versions.first?.notes ?? app.description, !notes.isEmpty { lines.append("\n\(notes)") }
        return lines.joined(separator: "\n")
    }
}
