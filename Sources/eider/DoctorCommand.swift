import ArgumentParser
import EiderKit
import Foundation

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Launch an installed app and, if it does not stay up, say why."
    )

    @Argument(help: "The app's bundle id.")
    var bundleID: String

    @Option(help: "Seconds to wait for the app to come up.")
    var timeout: Double = 20

    @OptionGroup var common: CommonOptions

    func run() async throws {
        try await common.guarded { output in
            let app = try await LaunchOutcome.installedApp(bundleID)
            let result = await LaunchProbe().launch(app, timeout: timeout)
            try LaunchOutcome.report(result, app: app, output: output, healthyText: "No problem found:")
        }
    }
}

/// What `open` and `doctor` share: finding the app and printing the probe's answer.
enum LaunchOutcome {
    struct Payload: Encodable {
        let running: Bool
        let pid: Int32?
        let diagnosis: LaunchDiagnosis?
    }

    static func installedApp(_ bundleID: String) async throws -> InstalledApp {
        guard let app = try await AppOperations().library.app(bundleID: bundleID) else {
            throw OperationFailure(code: "operations.not_installed", message: "No installed app has the bundle id \(bundleID).")
        }
        return app
    }

    /// Success prints the pid; a failure prints the diagnosis code and sentence
    /// (and the evidence), and the command exits 2. The JSON result carries the
    /// whole diagnosis under `data` as well as `error`.
    static func report(_ result: LaunchResult, app: InstalledApp, output: Output, healthyText: String) throws {
        switch result {
        case .running(let pid):
            output.result(Payload(running: true, pid: pid, diagnosis: nil), text: "\(healthyText) \(app.name) is running (pid \(pid)).")
        case .failed(let diagnosis):
            let report = FailureReport(code: "launch.\(diagnosis.code.rawValue)", message: diagnosis.summary, details: diagnosis.evidence)
            throw output.fail(report, data: Payload(running: false, pid: nil, diagnosis: diagnosis))
        }
    }
}
