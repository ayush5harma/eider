import ArgumentParser
import EiderKit
import Foundation

@main
struct EiderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eider",
        abstract: "Install iOS apps from sources as Mac apps.",
        version: EiderVersion.current,
        subcommands: [
            SourceCommand.self, SearchCommand.self, InfoCommand.self, InstallCommand.self,
            ListCommand.self, UpdateCommand.self, UninstallCommand.self, OpenCommand.self,
            DoctorCommand.self,
        ]
    )

    /// ArgumentParser exits 64 for a usage error; the contract here is 0
    /// success, 1 usage, 2 failure, so errors are mapped by hand. A command
    /// that failed has already printed its report and throws `ExitCode`.
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let exit as ExitCode {
            Foundation.exit(exit.rawValue)
        } catch {
            let status = exitCode(for: error)
            let text = fullMessage(for: error)
            if status == .success {
                if !text.isEmpty { print(text) }   // --help and --version
                Foundation.exit(0)
            }
            if !text.isEmpty { writeError(text) }
            Foundation.exit(1)
        }
    }
}
