import ArgumentParser
import EiderKit
import Foundation

/// Exit codes: 0 success, 1 usage (set in `EiderCommand.main`), 2 failure.
enum ExitStatus {
    static let failure = ExitCode(2)
}

/// One failure as the CLI reports it: a stable code, a sentence, and optional
/// detail lines (the evidence behind a launch diagnosis, for one).
struct FailureReport: Encodable {
    let code: String
    let message: String
    let details: [String]

    init(code: String, message: String, details: [String] = []) {
        self.code = code
        self.message = message
        self.details = details
    }

    init(_ failure: OperationFailure) {
        self.init(code: failure.code, message: failure.message)
    }
}

private struct ResultLine<Payload: Encodable>: Encodable {
    let type = "result"
    let ok: Bool
    let data: Payload?
    let error: FailureReport?
}

private struct EventLine: Encodable {
    let type = "event"
    let phase: String
    let step: String
    let message: String
    let fraction: Double
    let bytesReceived: Int64?
    let bytesTotal: Int64?

    init(_ event: OperationEvent) {
        phase = event.phase.rawValue
        step = event.step
        message = event.message
        fraction = event.fraction
        bytesReceived = event.bytesReceived
        bytesTotal = event.bytesTotal
    }
}

private struct Empty: Encodable {}

/// Everything a command prints. With `--json` stdout carries one JSON object
/// per line and the last is always a result object (`ok` true or false);
/// without it stdout is plain text and progress goes to stderr. No colour and
/// no emoji either way.
struct Output: Sendable {
    let json: Bool

    // MARK: Results

    func result<Payload: Encodable>(_ data: Payload, text: @autoclosure () -> String) {
        if json {
            line(ResultLine(ok: true, data: data, error: nil))
        } else {
            let body = DisplayText.escapingControls(text())
            if !body.isEmpty { print(body) }
        }
        fflush(stdout)
    }

    func result(text: @autoclosure () -> String) {
        result(Empty(), text: text())
    }

    /// Reports a failure and returns the exit status for the command to throw.
    /// `data` rides along in JSON mode (a diagnosis, for example).
    func fail<Payload: Encodable>(_ report: FailureReport, data: Payload?) -> ExitCode {
        if json {
            line(ResultLine(ok: false, data: data, error: report))
        } else {
            writeError("eider: \(report.message) (\(report.code))")
            for detail in report.details { writeError("  \(detail)") }
        }
        fflush(stdout)
        return ExitStatus.failure
    }

    func fail(_ report: FailureReport) -> ExitCode {
        fail(report, data: nil as Empty?)
    }

    func fail(_ error: Error) -> ExitCode {
        fail(FailureReport(OperationFailure.wrap(error)))
    }

    // MARK: Progress

    /// Download progress is thinned to every tenth of the bar so a log or pipe
    /// is not flooded; install steps are each worth a line.
    func progressHandler() -> @Sendable (OperationEvent) -> Void {
        let throttle = ProgressThrottle()
        let json = self.json
        return { event in
            if json {
                Output(json: true).line(EventLine(event))
            } else if throttle.shouldPrint(event) {
                writeError(String(format: "[%3d%%] %@", Int(event.fraction * 100), event.message))
            }
        }
    }

    fileprivate func line<T: Encodable>(_ value: T) {
        guard let data = try? Self.encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBucket = -1

    func shouldPrint(_ event: OperationEvent) -> Bool {
        guard event.phase == .download, event.step == "download" else { return true }
        let bucket = Int(event.fraction / OperationEvent.downloadShare * 10)
        return lock.withLock {
            guard bucket != lastBucket else { return false }
            lastBucket = bucket
            return true
        }
    }
}

/// Everything a person reads goes through here, so a control character from an IPA or a
/// source (an ESC that starts a terminal sequence, a bidi override) is shown, not obeyed.
func writeError(_ text: String) {
    FileHandle.standardError.write(Data((DisplayText.escapingControls(text) + "\n").utf8))
}

/// Plain aligned columns: each column as wide as its longest cell.
enum Table {
    static func render(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.indices.map { column in
                column == row.count - 1 ? row[column] : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
