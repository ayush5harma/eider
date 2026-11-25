import Foundation

/// The two places a failed launch leaves its reason: the unified log and a
/// crash report. Thin wrappers; the reasoning is in `LaunchClassifier`.
enum LaunchEvidence {
    static let logExecutable = "/usr/bin/log"
    static let defaultReportsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    // MARK: Log

    /// `log show` arguments for one process over a window. The predicate keeps
    /// the process's own messages and the kernel's lines that name it (System
    /// Policy and Sandbox denials are logged by the kernel, not by the app).
    static func logArguments(process: String, since start: Date) -> [String] {
        let quoted = process.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let predicate = "process == \"\(quoted)\" OR eventMessage CONTAINS \"\(quoted)\""
        return ["show", "--style", "compact", "--start", logTimestamp(start), "--predicate", predicate]
    }

    static func logLines(process: String, since start: Date) async -> [String] {
        let result = try? await ProcessRunner.runAsync(logExecutable, logArguments(process: process, since: start))
        guard let result, result.succeeded else { return [] }
        return lines(ofLogOutput: result.output)
    }

    /// One entry per non-empty line. An event with a backtrace prints its first
    /// line and then the frames as tab-indented continuation lines; they are
    /// kept verbatim because the classifier reads the throwing frame from them.
    static func lines(ofLogOutput output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init)
    }

    // MARK: The app's binaries

    /// File names of the Mach-O files inside an app bundle (the main
    /// executable, frameworks, dylibs, extensions), which is how a backtrace
    /// frame is told apart as the app's own code rather than the system's.
    /// Only the first bytes of each file are read (`MachOFiles.kind`).
    static func appBinaryNames(inBundle bundle: URL) -> Set<String> {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys) else { return [] }
        var names = Set<String>()
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: Set(keys)).isRegularFile) == true,
                  MachOFiles.kind(of: file) != .notMachO else { continue }
            names.insert(file.lastPathComponent)
        }
        return names
    }

    /// `log show --start` takes local time, "yyyy-MM-dd HH:mm:ss".
    static func logTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: Crash reports

    /// Newest `.ips` or `.crash` file for `process` written at or after `start`.
    /// File names are `<process>-<date>.ips` (or `<process>_<date>...`).
    static func newestCrashReport(process: String, in directory: URL, since start: Date) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let matches = files.compactMap { file -> (URL, Date)? in
            let name = file.lastPathComponent
            guard name.hasPrefix(process + "-") || name.hasPrefix(process + "_"),
                  file.pathExtension == "ips" || file.pathExtension == "crash",
                  let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  modified >= start else { return nil }
            return (file, modified)
        }
        return matches.max { $0.1 < $1.1 }?.0
    }

    /// The report's text, capped so a huge one cannot flood memory.
    static func lines(ofReport file: URL, maxBytes: Int = 512 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
    }
}
