import ArgumentParser
import EiderKit

struct SourceAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a source from its address.")

    @Argument(help: "The https address of the source file.")
    var url: String

    @OptionGroup var common: CommonOptions

    func run() async throws {
        try await common.guarded { output in
            let source = try await AppOperations().sources.add(url: try sourceURL(from: url))
            let warnings = source.warnings.map { "warning: \($0)" }
            var lines = ["Added \(source.name): \(source.apps.count) app(s)"]
            if let entries = source.entryCount {
                lines.append("\(entries) entries listed; those sharing a bundle id were merged into one app each.")
            }
            output.result(
                SourceSummary(source),
                text: (lines + warnings).joined(separator: "\n"))
        }
    }
}
