import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data

    public var succeeded: Bool { status == 0 }
    public var output: String { String(decoding: standardOutput, as: UTF8.self) }
    /// Standard error on one line, so a tool's multi-line complaint reads as one sentence.
    public var errorLine: String {
        String(decoding: standardError, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct ProcessLaunchError: Error, CustomStringConvertible {
    public let executable: String
    public let reason: String
    public var description: String { "could not run \(executable): \(reason)" }
}

/// Runs one external program and collects its output. Only the programs the
/// architecture allows on the install path go through here (codesign, unzip,
/// lsregister, open); callers pass absolute paths, never a lookup through PATH.
public enum ProcessRunner {
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ProcessLaunchError(executable: executable, reason: error.localizedDescription)
        }
        // Both pipes are drained at once: a program that fills one while this
        // waits on the other would block forever.
        let errorBox = DataBox()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            errorBox.data = (try? error.fileHandleForReading.readToEnd()) ?? Data()
            drained.leave()
        }
        let outputData = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        drained.wait()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, standardOutput: outputData, standardError: errorBox.data)
    }

    public static func runAsync(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try run(executable, arguments, environment: environment)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
