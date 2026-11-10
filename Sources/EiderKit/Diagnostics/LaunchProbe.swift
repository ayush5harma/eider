import Foundation

/// Opens an installed app in the background and says whether it stays up or,
/// if not, why. Used by `eider open`, `eider doctor` and the app's "Open" and
/// "Why won't it open?" actions.
public struct LaunchProbe: Sendable {
    private static let openExecutable = "/usr/bin/open"
    private static let pollInterval: TimeInterval = 0.25
    /// The unified log flushes a moment after a process dies.
    private static let logFlushDelay: TimeInterval = 1

    private let reportsDirectory: URL
    private let settle: TimeInterval
    private let reportWait: TimeInterval

    /// - Parameters:
    ///   - settle: how long the process must stay alive to count as running. A
    ///     broken app is often visible for a moment before dyld or AMFI kills it.
    ///   - reportWait: how long to wait for a crash report when the log alone
    ///     does not explain the failure (CrashReporter writes it seconds later).
    public init(
        reportsDirectory: URL? = nil,
        settle: TimeInterval = 2,
        reportWait: TimeInterval = 8
    ) {
        self.reportsDirectory = reportsDirectory ?? LaunchEvidence.defaultReportsDirectory
        self.settle = settle
        self.reportWait = reportWait
    }

    /// Opens `app` with `open -g` (no focus change) and waits up to `timeout`
    /// seconds. `.running` carries the process id; `.failed` carries a diagnosis.
    public func launch(_ app: InstalledApp, timeout: TimeInterval = 20) async -> LaunchResult {
        guard let process = Self.executableName(of: app) else {
            return .failed(LaunchDiagnosis(
                code: .unknown,
                summary: "The installed app has no readable Info.plist, so it cannot be opened; reinstall it.",
                evidence: [app.path.path]))
        }
        let start = Date().addingTimeInterval(-1)
        if let refusal = await open(app) { return .failed(refusal) }

        let deadline = Date().addingTimeInterval(timeout)
        var firstSeen: Date?
        while Date() < deadline {
            let pids = RunningProcesses.pids(insideBundle: app.path)
            if let pid = pids.first {
                let seen = firstSeen ?? Date()
                firstSeen = seen
                if Date().timeIntervalSince(seen) >= settle { return .running(pid: pid) }
            } else if firstSeen != nil {
                break   // it appeared and then exited
            }
            await sleep(Self.pollInterval)
        }
        let appeared = firstSeen != nil
        return .failed(await diagnose(process: process, since: start, appeared: appeared, timeout: timeout))
    }

    // MARK: Steps

    /// `open` refusing (damaged bundle, bad executable) leaves no process to look at.
    private func open(_ app: InstalledApp) async -> LaunchDiagnosis? {
        do {
            let result = try await ProcessRunner.runAsync(Self.openExecutable, ["-g", app.path.path])
            guard !result.succeeded else { return nil }
            let reason = result.errorLine.isEmpty ? "exit status \(result.status)" : result.errorLine
            return LaunchDiagnosis(
                code: .openFailed,
                summary: "macOS refused to open the app: \(reason)",
                evidence: [reason])
        } catch {
            return LaunchDiagnosis(code: .openFailed, summary: "Could not run /usr/bin/open: \(error)", evidence: [])
        }
    }

    private func diagnose(process: String, since start: Date, appeared: Bool, timeout: TimeInterval) async -> LaunchDiagnosis {
        await sleep(Self.logFlushDelay)
        let log = await LaunchEvidence.logLines(process: process, since: start)
        var diagnosis = LaunchClassifier.classify(lines: log, processName: process)
        if diagnosis.code == .unknown, let report = await waitForReport(process: process, since: start) {
            diagnosis = LaunchClassifier.classify(lines: log + LaunchEvidence.lines(ofReport: report), processName: process)
        }
        guard diagnosis.code == .unknown else { return diagnosis }
        let note = appeared
            ? "The app started and then exited within \(Int(timeout)) seconds."
            : "The app did not start within \(Int(timeout)) seconds."
        return LaunchDiagnosis(code: .unknown, summary: diagnosis.summary, evidence: [note] + diagnosis.evidence)
    }

    private func waitForReport(process: String, since start: Date) async -> URL? {
        let deadline = Date().addingTimeInterval(reportWait)
        repeat {
            if let report = LaunchEvidence.newestCrashReport(process: process, in: reportsDirectory, since: start) { return report }
            await sleep(Self.pollInterval * 2)
        } while Date() < deadline
        return nil
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Mac Catalyst apps keep Info.plist in Contents/, iOS-layout bundles at the top.
    static func executableName(of app: InstalledApp) -> String? {
        ["Contents/Info.plist", "Info.plist"].lazy
            .compactMap { try? InfoPlist(url: app.path.appendingPathComponent($0)) }
            .compactMap { $0.string("CFBundleExecutable") }
            .first
    }
}
