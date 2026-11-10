import ArgumentParser
import EiderKit

@main
struct EiderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eider",
        abstract: "Install iOS apps from sources as Mac apps.",
        version: EiderVersion.current
    )

    func run() throws {
        print(Self.helpMessage())
    }
}
