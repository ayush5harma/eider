import ArgumentParser
import EiderKit
import Foundation

struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show what a source offers for an app, and whether it is installed.")

    @Argument(help: "The app's bundle id.")
    var bundleID: String

    @OptionGroup var common: CommonOptions

    private struct Payload: Encodable {
        let app: CatalogApp
        let source: String
        let installed: InstalledApp?
    }

    func run() async throws {
        try await common.guarded { output in
            let operations = AppOperations()
            guard let entry = try await operations.catalogEntry(bundleID: bundleID) else {
                throw output.fail(FailureReport(code: "operations.not_in_catalog", message: "None of your sources lists \(bundleID)."))
            }
            let installed = try await operations.library.app(bundleID: bundleID)
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
