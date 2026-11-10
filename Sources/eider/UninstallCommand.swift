import ArgumentParser
import EiderKit

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Move an installed app to the Trash and forget it."
    )

    @Argument(help: "The app's bundle id.")
    var bundleID: String

    @Flag(name: .customLong("remove-data"), help: "Also move the app's data container to the Trash.")
    var removeData = false

    @OptionGroup var common: CommonOptions

    private struct Payload: Encodable {
        let removed: String
        let dataRemoved: Bool
    }

    func run() async throws {
        try await common.guarded { output in
            try await AppOperations().uninstall(bundleID: bundleID, removeData: removeData)
            output.result(Payload(removed: bundleID, dataRemoved: removeData), text: "Removed \(bundleID)")
        }
    }
}
