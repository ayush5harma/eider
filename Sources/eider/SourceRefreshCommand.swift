import ArgumentParser
import EiderKit

struct SourceRefreshCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "refresh", abstract: "Fetch a source again (every source when no address is given).")

    @Argument(help: "The address of one source; omit to refresh all.")
    var url: String?

    @OptionGroup var common: CommonOptions

    private struct Row: Encodable {
        let url: String
        let ok: Bool
        let apps: Int?
        let error: FailureReport?
    }

    private struct Payload: Encodable { let results: [Row] }

    func run() async throws {
        try await common.guarded { output in
            let store = AppOperations().sources
            var rows: [Row] = []
            if let url {
                let address = try sourceURL(from: url)
                do {
                    rows = [Row(url: address.absoluteString, ok: true, apps: try await store.refresh(url: address).apps.count, error: nil)]
                } catch {
                    rows = [Row(url: address.absoluteString, ok: false, apps: nil, error: FailureReport(OperationFailure.wrap(error)))]
                }
            } else {
                rows = try await store.refreshAll().map { entry in
                    switch entry.result {
                    case .success(let source):
                        return Row(url: entry.url.absoluteString, ok: true, apps: source.apps.count, error: nil)
                    case .failure(let error):
                        return Row(url: entry.url.absoluteString, ok: false, apps: nil, error: FailureReport(OperationFailure.wrap(error)))
                    }
                }
            }
            let text = rows.isEmpty ? "No sources added." : rows.map { row in
                row.ok ? "Refreshed \(row.url): \(row.apps ?? 0) app(s)" : "Failed \(row.url): \(row.error?.message ?? "unknown error")"
            }.joined(separator: "\n")
            if let failed = rows.first(where: { !$0.ok }), let report = failed.error {
                if output.json { _ = output.fail(report, data: Payload(results: rows)) } else {
                    print(text)
                    _ = output.fail(report)
                }
                throw ExitStatus.failure
            }
            output.result(Payload(results: rows), text: text)
        }
    }
}
