import Foundation

/// One progress report from `AppOperations`, covering both phases of an
/// install: the download, then the install steps. The CLI prints these (or one
/// JSON object each with `--json`) and the app draws a progress bar from them.
public struct OperationEvent: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case download, install
    }

    public let phase: Phase
    /// `"download"` while downloading, otherwise an `InstallStep` raw value
    /// (`unpack`, `convert`, `sign`, ..., `done`, `warning`).
    public let step: String
    /// A sentence for a person.
    public let message: String
    /// 0 to 1 over the whole operation, download and install together.
    public let fraction: Double
    /// Download phase only; `bytesTotal` is nil when the server did not say.
    public let bytesReceived: Int64?
    public let bytesTotal: Int64?

    public init(
        phase: Phase, step: String, message: String, fraction: Double,
        bytesReceived: Int64? = nil, bytesTotal: Int64? = nil
    ) {
        self.phase = phase
        self.step = step
        self.message = message
        self.fraction = min(max(fraction, 0), 1)
        self.bytesReceived = bytesReceived
        self.bytesTotal = bytesTotal
    }

    /// The share of the whole operation the download takes when there is one.
    /// A fixed split: an IPA's download time and its conversion time are not
    /// related, so any ratio is a guess, and this one keeps both phases visible.
    public static let downloadShare = 0.4

    /// An install event, placed after the download when there was one.
    static func install(_ event: InstallEvent, afterDownload: Bool) -> OperationEvent {
        let base = afterDownload ? downloadShare : 0
        return OperationEvent(
            phase: .install, step: event.step.rawValue, message: event.message,
            fraction: base + event.fraction * (1 - base))
    }
}

/// Turns the download module's events into `OperationEvent`s, dropping the
/// progress reports that would not move the bar (a chunk arrives every few KB).
struct DownloadEventMapper {
    private var lastPercent = -1
    private var lastBytes: Int64 = 0
    private let label: String

    init(label: String) { self.label = label }

    mutating func map(_ event: DownloadEvent) -> OperationEvent? {
        switch event {
        case .started(let expected):
            return progress(0, expected, message: "Downloading \(label)")
        case .progress(let received, let expected):
            if let expected, expected > 0 {
                let percent = Int(Double(received) / Double(expected) * 100)
                guard percent != lastPercent else { return nil }
                lastPercent = percent
            } else {
                guard received - lastBytes >= 1_048_576 else { return nil }
                lastBytes = received
            }
            return progress(received, expected, message: "Downloading \(label)")
        case .finished(_, let sha256):
            return OperationEvent(
                phase: .download, step: "download", message: "Downloaded \(label) (sha256 \(sha256.prefix(12)))",
                fraction: OperationEvent.downloadShare)
        }
    }

    private func progress(_ received: Int64, _ expected: Int64?, message: String) -> OperationEvent {
        let share = expected.flatMap { $0 > 0 ? Double(received) / Double($0) : nil } ?? 0
        return OperationEvent(
            phase: .download, step: "download", message: message,
            fraction: share * OperationEvent.downloadShare, bytesReceived: received, bytesTotal: expected)
    }
}
