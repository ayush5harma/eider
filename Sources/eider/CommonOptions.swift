import ArgumentParser
import EiderKit
import Foundation

/// The flag every command takes.
struct CommonOptions: ParsableArguments {
    @Flag(help: "Print JSON, one object per line; the last line is the result.")
    var json = false

    var output: Output { Output(json: json) }

    /// Runs a command body and turns anything it throws into a reported
    /// failure with exit status 2. Usage errors never reach here: ArgumentParser
    /// rejects them before `run`.
    func guarded(_ body: (Output) async throws -> Void) async throws {
        let output = self.output
        do {
            try await body(output)
        } catch let exit as ExitCode {
            throw exit
        } catch is CancellationError {
            throw ExitCode(130)
        } catch {
            throw output.fail(error)
        }
    }
}

/// A bundle id typed on the command line becomes a path (the data container),
/// so it gets the same check as one read from an IPA.
func requireBundleID(_ text: String) throws {
    guard BundleIdentifier.isValid(text) else {
        throw ValidationError("\(text) is not a bundle id: use dot-separated letters, digits, - and _ (for example com.example.app).")
    }
}

/// Parses the text of a source address: an https or loopback URL, or a path to
/// a local file (handy for testing a source before publishing it).
func sourceURL(from text: String) throws -> URL {
    let expanded = (text as NSString).expandingTildeInPath
    if !text.contains("://"), FileManager.default.fileExists(atPath: expanded) {
        return URL(fileURLWithPath: expanded)
    }
    guard let url = URL(string: text), url.scheme != nil else {
        throw OperationFailure(code: "cli.bad_url", message: "\(text) is not a web address. Use the full https:// address of the source file.")
    }
    return url
}
