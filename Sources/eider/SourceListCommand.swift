import ArgumentParser
import EiderKit

struct SourceListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the sources you have added.")

    @OptionGroup var common: CommonOptions

    private struct Payload: Encodable { let sources: [SourceSummary] }

    func run() async throws {
        try await common.guarded { output in
            let sources = try await AppOperations().sources.sources
            let text = sources.isEmpty
                ? "No sources added. Add one with: eider source add <url>"
                : Table.render(["NAME", "APPS", "ADDRESS"], sources.map { [$0.name, String($0.apps.count), $0.url.absoluteString] })
            output.result(Payload(sources: sources.map(SourceSummary.init)), text: text)
        }
    }
}
