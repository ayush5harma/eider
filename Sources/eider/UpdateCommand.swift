import ArgumentParser
import EiderKit

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Reinstall the newest version of an app, keeping its data."
    )

    @Argument(help: "The app's bundle id.")
    var bundleID: String?

    @Flag(name: .customLong("all"), help: "Update every app that has an update.")
    var all = false

    @OptionGroup var common: CommonOptions

    private struct Payload: Encodable {
        let updated: [InstalledApp]
        let current: [String]
    }

    func validate() throws {
        guard (bundleID != nil) != all else {
            throw ValidationError("Give a bundle id, or --all (not both).")
        }
    }

    func run() async throws {
        try await common.guarded { output in
            let operations = AppOperations()
            var ids: [String] = []
            if let bundleID { ids = [bundleID] } else { ids = try await operations.availableUpdates().map(\.installed.bundleID) }
            var updated: [InstalledApp] = []
            var current: [String] = []
            for id in ids {
                if let app = try await operations.update(bundleID: id, onEvent: output.progressHandler()) {
                    updated.append(app)
                } else {
                    current.append(id)
                }
            }
            let lines = updated.map { "Updated \($0.name) to \($0.version)" } + current.map { "\($0) is up to date" }
            output.result(Payload(updated: updated, current: current), text: lines.isEmpty ? "Everything is up to date." : lines.joined(separator: "\n"))
        }
    }
}
