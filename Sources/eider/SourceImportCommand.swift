import ArgumentParser
import EiderKit
import Foundation

struct SourceImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Add the sources listed in a file.",
        discussion: """
            Reads an Eider sources file (from eider source export), a JSON array of addresses, \
            or plain text with one address per line (# starts a comment). Addresses already added are skipped. \
            Exits with status 2 when any address was rejected or failed, after adding the rest.
            """)

    @Argument(help: "The file to read, or - for standard input.")
    var file: String

    @OptionGroup var common: CommonOptions

    func run() async throws {
        try await common.guarded { out in
            let data: Data
            if file == "-" {
                data = try SourceListIO.read(from: .standardInput)
            } else {
                data = try SourceListIO.read(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
            }
            let store = AppOperations().sources
            let existing = try await store.sources.map(\.url)
            let json = common.json
            let result = try await SourceListIO.importList(
                data, existing: existing,
                add: { try await store.add(url: $0) },
                onProgress: { done, total in
                    if !json, done > 0 { writeError("[\(done)/\(total)] sources fetched") }
                })
            let text = ([result.summary] + result.problemLines).joined(separator: "\n")
            guard result.hasProblems else {
                out.result(result, text: text)
                return
            }
            throw out.fail(
                FailureReport(code: "sources.import_incomplete", message: result.summary, details: result.problemLines),
                data: result)
        }
    }
}
