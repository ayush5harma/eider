import Foundation

/// Decides why a launch failed from text lines (the unified log over the launch
/// window and the newest crash report). A pure function: the log query and the
/// file reads live elsewhere, so every rule here is tested with sample lines.
public enum LaunchClassifier {
    static let maxEvidenceLines = 6
    static let maxEvidenceWidth = 300

    /// Rules in priority order: a crash cause outranks the denials that are
    /// logged alongside it on most launches. `processName` scopes the kernel's
    /// System Policy and Sandbox lines, which name the process that was refused.
    /// `appBinaries` is the set of Mach-O file names inside the installed bundle;
    /// it lets an uncaught exception say which of the app's own binaries threw.
    public static func classify(lines rawLines: [String], processName: String?, appBinaries: Set<String> = []) -> LaunchDiagnosis {
        let lines = expand(rawLines)
        // First, ahead of every dyld, AMFI and denial rule: a process that
        // logged "Terminating app due to uncaught exception" got past dyld and
        // code signing and ran app code, so those cannot be why it died, while
        // the keyword rules below match substrings that a running app also logs
        // for benign reasons (a handled -34018, a denied read, a dlopen that
        // failed and was caught). An app killed by AMFI or dyld never reaches
        // the exception machinery, so it has no such line.
        if let diagnosis = uncaughtException(in: lines, appBinaries: appBinaries) { return diagnosis }
        if let hit = first(lines, matching: ["FairPlay", "cryptid", "file is encrypted", "binary is encrypted"]) {
            return LaunchDiagnosis(
                code: .encryptedBinary,
                summary: "The app's binary is still FairPlay-encrypted (an App Store copy), so it cannot run; install a decrypted IPA.",
                evidence: evidence(hit))
        }
        if let hit = first(lines, matching: [
            "code signature invalid", "Code Signature Invalid", "CODESIGNING", "code signature validation failed",
            "invalid signature", "Invalid Signature", "a sealed resource is missing or invalid",
        ]) {
            return LaunchDiagnosis(
                code: .invalidSignature,
                summary: "macOS rejected the app's code signature and killed it at launch; reinstall the app so it is signed again.",
                evidence: evidence(hit))
        }
        if let hit = first(lines, matching: ["Library not loaded"]) {
            let library = value(after: "Library not loaded:", in: hit.first ?? "") ?? "a library"
            return LaunchDiagnosis(
                code: .libraryNotLoaded,
                summary: "The app needs \(library), which it cannot load; the IPA may be incomplete or the library is missing on this Mac.",
                evidence: evidence(hit))
        }
        if let hit = first(lines, matching: ["Symbol not found"]) {
            let symbol = value(after: "Symbol not found:", in: hit.first ?? "") ?? "a function"
            return LaunchDiagnosis(
                code: .symbolNotFound,
                summary: "The app needs \(symbol), which this version of macOS does not provide, so it cannot run here.",
                evidence: evidence(hit))
        }
        if let hit = first(lines, matching: ["-34018", "errSecMissingEntitlement"]) {
            return LaunchDiagnosis(
                code: .keychainEntitlement,
                summary: "The app could not use the keychain (error -34018, no keychain access group); reinstall it without --no-keychain so the keychain shim is linked.",
                evidence: evidence(hit))
        }
        if let hit = first(lines, matching: ["System Policy:"], process: processName) {
            return LaunchDiagnosis(
                code: .systemPolicy,
                summary: "macOS denied the app access to a protected location (System Policy), usually an app-group folder; reinstall with this version of Eider, or grant the app Full Disk Access.",
                evidence: evidence(hit))
        }
        if let hit = first(lines, matching: ["Sandbox:", "com.apple.sandbox.reporting"], process: processName) {
            return LaunchDiagnosis(
                code: .sandboxDenial,
                summary: "The app's sandbox refused something it tried to do (see the evidence); it may need an entitlement that Eider does not grant.",
                evidence: evidence(hit))
        }
        let relevant = lines.filter { processName.map($0.contains) ?? true }
        return LaunchDiagnosis(
            code: .unknown,
            summary: "The app did not stay running and the logs do not say why; the last relevant lines are listed below.",
            evidence: evidence(Array((relevant.isEmpty ? lines : relevant).suffix(maxEvidenceLines))))
    }

    // MARK: Uncaught exceptions

    private static let exceptionMarker = "Terminating app due to uncaught exception"
    private static let exceptionPattern = try! NSRegularExpression(
        pattern: #"Terminating app due to uncaught exception '([^']+)'(?:, reason: '(.*)')?"#)
    /// A symbolicated backtrace line: index, image name (which may hold
    /// spaces), 0x address, then the symbol with its "+ offset".
    private static let framePattern = try! NSRegularExpression(
        pattern: #"^\d+\s+(.+?)\s+0x[0-9a-fA-F]+\s+(.*?)(?:\s+\+\s+\d+)?$"#)

    /// The backtrace frames follow the "Terminating" line (log continuation
    /// lines, or the crash report's "Last Exception Backtrace"), so only lines
    /// after it are searched. A crash report saved as .ips keeps its frames as
    /// JSON objects, not text, so it yields the exception but no "thrown from".
    private static func uncaughtException(in lines: [String], appBinaries: Set<String>) -> LaunchDiagnosis? {
        guard let index = lines.firstIndex(where: { $0.contains(exceptionMarker) }),
              let match = captures(exceptionPattern, in: lines[index]) else { return nil }
        let name = match[0] ?? "exception"
        var summary = "The app stopped on an uncaught \(name)"
        if match.count > 1, let reason = match[1], !reason.isEmpty { summary += " (\(reason))" }
        var evidenceLines = [lines[index]]
        if let frame = lines[(index + 1)...].lazy.compactMap({ appFrame(in: $0, binaries: appBinaries) }).first {
            summary += ", thrown from \(frame.image)"
            if !frame.symbol.isEmpty, !frame.symbol.hasPrefix("0x") { summary += " in \(frame.symbol)" }
            evidenceLines.append(frame.line)
        }
        return LaunchDiagnosis(code: .uncaughtException, summary: summary + ".", evidence: evidence(evidenceLines))
    }

    private static func appFrame(in line: String, binaries: Set<String>) -> (image: String, symbol: String, line: String)? {
        guard let match = captures(framePattern, in: line), let image = match[0], binaries.contains(image) else { return nil }
        return (image, (match.count > 1 ? match[1] : nil) ?? "", line)
    }

    /// The capture groups of the first match; nil for a group that did not take part.
    private static func captures(_ regex: NSRegularExpression, in line: String) -> [String?]? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).map { group in
            Range(match.range(at: group), in: line).map { String(line[$0]) }
        }
    }

    // MARK: Internals

    /// A crash report saved as .ips keeps its text in JSON strings, where a
    /// line break is the two characters backslash and n; split on those too.
    private static func expand(_ lines: [String]) -> [String] {
        lines.flatMap { $0.components(separatedBy: "\\n") }
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Every line containing one of `needles`, or nil when none does.
    private static func first(_ lines: [String], matching needles: [String], process: String? = nil) -> [String]? {
        let hits = lines.filter { line in
            needles.contains { line.contains($0) } && (process.map { line.contains($0) } ?? true)
        }
        return hits.isEmpty ? nil : hits
    }

    private static func evidence(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.compactMap { line -> String? in
            let shortened = line.count > maxEvidenceWidth ? String(line.prefix(maxEvidenceWidth)) + "..." : line
            return seen.insert(shortened).inserted ? shortened : nil
        }.prefix(maxEvidenceLines).map { $0 }
    }

    private static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let cut = rest.firstIndex(where: { $0 == "(" || $0 == "," || $0 == "\"" }) ?? rest.endIndex
        let text = rest[..<cut].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
