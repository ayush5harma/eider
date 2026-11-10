import ArgumentParser
import EiderKit

@main
struct EiderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eider",
        abstract: "Install iOS apps from sources as Mac apps.",
        version: EiderVersion.current,
        subcommands: [InstallCommand.self, UninstallCommand.self]
    )
}
