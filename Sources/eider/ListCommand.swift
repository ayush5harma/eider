import ArgumentParser
import EiderKit
import Foundation

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List installed apps and mark those with an update.")

    @OptionGroup var common: CommonOptions

    private struct Row: Encodable {
        let app: InstalledApp
        let update: UpdateInfo?
    }

    private struct UpdateInfo: Encodable {
        let version: String
        let build: String?
        let source: String
    }

    private struct Payload: Encodable { let apps: [Row] }

    func run() async throws {
        try await common.guarded { output in
            let operations = AppOperations()
            let apps = try await operations.library.all()
            let updates = Dictionary(uniqueKeysWithValues: try await operations.availableUpdates().map { ($0.installed.bundleID, $0) })
            let rows = apps.map { app in
                Row(app: app, update: updates[app.bundleID].map {
                    UpdateInfo(version: $0.version.version, build: $0.version.build, source: $0.sourceURL.absoluteString)
                })
            }
            let table = Table.render(
                ["NAME", "BUNDLE ID", "VERSION", "UPDATE", "PATH"],
                rows.map { [$0.app.name, $0.app.bundleID, $0.app.version, $0.update.map { "-> \($0.version)" } ?? "-", $0.app.path.path] })
            output.result(Payload(apps: rows), text: rows.isEmpty ? "No apps installed." : table)
        }
    }
}
