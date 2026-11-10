import ArgumentParser
import EiderKit

struct SourceRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a source. Apps installed from it stay installed.")

    @Argument(help: "The address the source was added with.")
    var url: String

    @OptionGroup var common: CommonOptions

    private struct Payload: Encodable { let removed: String }

    func run() async throws {
        try await common.guarded { output in
            let address = try sourceURL(from: url)
            try await AppOperations().sources.remove(url: address)
            output.result(Payload(removed: address.absoluteString), text: "Removed \(address.absoluteString)")
        }
    }
}
