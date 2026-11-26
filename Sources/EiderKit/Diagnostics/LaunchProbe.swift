import Foundation

/// Opens an installed app in the background and says whether it stays up or,
/// if not, why. Used by `eider open`, `eider doctor` and the app's "Open" and
/// "Why won't it open?" actions.
public struct LaunchProbe: Sendable {
    private static let openExecutable = "/usr/bin/open"
    private static let pollInterval: TimeInterval = 0.25
    /// The unified log flushes a moment after a process dies.
    private static let logFlushDelay: TimeInterval = 1

    /// How long a process must stay up to count as running. Measured 2026-11-25
    /// on macOS 27.3 with a real 115 MB IPA (Nicegram 1.7.8): its first log line
    /// came 3.9 s before an uncaught exception ended it, and the process was
    /// dead 4.4 s after it first showed. A 2 s settle called that app running
    /// about 2 s before it crashed. 8 s is about twice the measured 4.4 s; an
    /// app that fails later than this is the app's own problem to report, and
    /// `--settle` raises the bar for one that is slow to fail.
    public static let defaultSettle: TimeInterval = 8

    private let reportsDirectory: URL
    private let settle: TimeInterval
    private let reportWait: TimeInterval

    /// - Parameters:
    ///   - settle: how long the process must stay alive to count as running. A
    ///     broken app is often visible for a moment before dyld or AMFI kills
    ///     it, or runs for several seconds before it throws (see `defaultSettle`).
    ///   - reportWait: how long to wait for a crash report when the log alone
    ///     does not explain the failure (CrashReporter writes it seconds later;
    ///     one report in the field above arrived 35 s after the crash).
    public init(
        reportsDirectory: URL? = nil,
        settle: TimeInterval = LaunchProbe.defaultSettle,
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

        let bundle = app.path
        let outcome = await watch(timeout: timeout) { RunningProcesses.pids(insideBundle: bundle) }
        if case .settled(let pid) = outcome {
            if let empty = await emptyWindow(pid: pid, process: process, since: start) { return .failed(empty) }
            return .running(pid: pid)
        }
        let appeared = outcome != .neverAppeared
        return .failed(await diagnose(app, process: process, since: start, appeared: appeared, timeout: timeout))
    }

    enum Watch: Equatable {
        case settled(pid: Int32)
        /// A process appeared and was gone again before `settle` elapsed.
        case exited
        /// No process appeared before `timeout` ran out.
        case neverAppeared
    }

    /// Polls `pids` until a process has been alive for `settle`, has come and
    /// gone, or `timeout` runs out with nothing seen. Separate from `launch` so
    /// the settle rule is tested with a stand-in process list instead of a real app.
    ///
    /// `timeout` bounds the wait for a process to appear. Once one has been
    /// seen the watch runs on to `firstSeen + settle` even past the deadline
    /// (that bounds it), because a process first seen at 13 s of a 20 s timeout
    /// with an 8 s settle is still alive at 20 s and must not be reported as
    /// exited.
    func watch(timeout: TimeInterval, pids: @Sendable () -> [Int32]) async -> Watch {
        let deadline = Date().addingTimeInterval(timeout)
        var firstSeen: Date?
        while true {
            if let pid = pids().first {
                let seen = firstSeen ?? Date()
                firstSeen = seen
                if Date().timeIntervalSince(seen) >= settle { return .settled(pid: pid) }
            } else if firstSeen != nil {
                return .exited
            } else if Date() >= deadline {
                return .neverAppeared
            }
            await sleep(Self.pollInterval)
        }
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

    private func diagnose(_ app: InstalledApp, process: String, since start: Date, appeared: Bool, timeout: TimeInterval) async -> LaunchDiagnosis {
        await sleep(Self.logFlushDelay)
        let log = await LaunchEvidence.logLines(process: process, since: start)
        var diagnosis = classify(log, app: app, process: process)
        if diagnosis.code == .unknown, let report = await waitForReport(process: process, since: start) {
            diagnosis = classify(log + LaunchEvidence.lines(ofReport: report), app: app, process: process)
        }
        guard diagnosis.code == .unknown else { return diagnosis }
        return LaunchDiagnosis(code: .unknown, summary: diagnosis.summary, evidence: [failureNote(appeared: appeared, timeout: timeout)] + diagnosis.evidence)
    }

    /// A running app whose window is empty (`LaunchClassifier.emptyWindow`).
    /// The window is read first because it is cheap and settles almost every
    /// launch: a window with content, or no Accessibility permission, ends the
    /// check before the log is read (`log show` takes seconds).
    private func emptyWindow(pid: Int32, process: String, since start: Date) async -> LaunchDiagnosis? {
        guard WindowContent.contentElements(pid: pid, limit: 1) == 0 else { return nil }
        let log = await LaunchEvidence.logLines(process: process, since: start)
        return LaunchClassifier.emptyWindow(lines: log, processName: process, contentElements: 0)
    }

    /// Only an app that was seen and then died is said to have exited; one that
    /// was never seen did not start. An app still alive never reaches here.
    func failureNote(appeared: Bool, timeout: TimeInterval) -> String {
        appeared
            ? "The app started and then exited before it had stayed up for \(String(format: "%g", settle)) seconds."
            : "The app did not start within \(String(format: "%g", timeout)) seconds."
    }

    /// The bundle is walked for its binaries only when an exception line is
    /// there to use them on, so an app with thousands of resources does not pay
    /// for the walk on every failed launch.
    private func classify(_ lines: [String], app: InstalledApp, process: String) -> LaunchDiagnosis {
        let hasException = lines.contains { $0.contains(LaunchClassifier.exceptionMarker) }
        let binaries = hasException ? LaunchEvidence.appBinaryNames(inBundle: app.path) : []
        return LaunchClassifier.classify(lines: lines, processName: process, appBinaries: binaries)
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
