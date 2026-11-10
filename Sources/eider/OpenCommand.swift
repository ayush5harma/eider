import ArgumentParser
import EiderKit

struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open an installed app in the background and confirm it stays running."
    )

    @Argument(help: "The app's bundle id.")
    var bundleID: String

    @Option(help: "Seconds to wait for the app to come up.")
    var timeout: Double = 20

    @OptionGroup var common: CommonOptions

    func run() async throws {
        try await common.guarded { output in
            let app = try await LaunchOutcome.installedApp(bundleID)
            let result = await LaunchProbe().launch(app, timeout: timeout)
            try LaunchOutcome.report(result, app: app, output: output, healthyText: "Opened")
        }
    }
}
