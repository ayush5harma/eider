import ArgumentParser
import EiderKit
import Foundation

struct SourceExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write the sources you have added as a file you can import elsewhere.",
        discussion: "JSON is the Eider sources file; text is one address per line. Output goes to stdout unless --output is given.")

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case json, text
    }

    @Option(help: "json (default) or text.")
    var format: Format = .json

    @Option(name: [.short, .long], help: "Write to this file instead of stdout.")
    var output: String?

    @OptionGroup var common: CommonOptions

    private struct Payload: Encodable {
        let format: String
        let count: Int
        let path: String?
        /// Only without --output, so the result line carries the list itself.
        let content: String?
    }

    func run() async throws {
        try await common.guarded { out in
            let sources = try await AppOperations().sources.sources
            let content: String
            switch format {
            case .json: content = String(decoding: try SourceListIO.exportJSON(sources), as: UTF8.self) + "\n"
            case .text: content = SourceListIO.exportText(sources)
            }
            guard let output else {
                if common.json {
                    out.result(Payload(format: format.rawValue, count: sources.count, path: nil, content: content), text: "")
                } else {
                    FileHandle.standardOutput.write(Data(content.utf8))
                }
                return
            }
            let path = (output as NSString).expandingTildeInPath
            do {
                try Data(content.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                throw OperationFailure(code: "sources.export_failed", message: "Could not write \(path): \(error.localizedDescription)")
            }
            out.result(
                Payload(format: format.rawValue, count: sources.count, path: path, content: nil),
                text: "Wrote \(sources.count) source(s) to \(path)")
        }
    }
}
