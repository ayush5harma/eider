import Foundation

/// The prebuilt dylibs the engine links into installed apps
/// (`Scripts/build-shims.sh` makes them).
public enum Shim: String, CaseIterable, Sendable {
    case keychain = "libipakeychain.dylib"
    case gles = "libipagles.dylib"
    case groups = "libipagroups.dylib"
    /// Empty library that stands in for a keychain-fix tweak.
    case neutralised = "libipaneutralised.dylib"

    /// Where the app loads it from once linked.
    public var installName: String { "@executable_path/Frameworks/\(rawValue)" }
}

/// Finds shims at run time, in the order ARCHITECTURE.md fixes: the
/// `EIDER_SHIMS_DIR` override, then beside the executable
/// (`../share/eider/shims`), then inside the app bundle
/// (`Contents/Resources/shims`). The first directory holding the file wins.
public struct ShimLocator: Sendable {
    public static let overrideVariable = "EIDER_SHIMS_DIR"

    public let searchDirectories: [URL]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
        resourceURL: URL? = Bundle.main.resourceURL
    ) {
        var directories: [URL] = []
        if let override = environment[Self.overrideVariable], !override.isEmpty {
            directories.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let executableURL {
            directories.append(
                executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
                    .appendingPathComponent("../share/eider/shims", isDirectory: true).standardizedFileURL
            )
        }
        if let resourceURL {
            directories.append(resourceURL.appendingPathComponent("shims", isDirectory: true))
        }
        searchDirectories = directories
    }

    public func url(for shim: Shim) throws -> URL {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(shim.rawValue)
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
        }
        let tried = searchDirectories.map(\.path).joined(separator: ", ")
        throw InstallFailure(
            .missingShim,
            "The helper library \(shim.rawValue) was not found (looked in: \(tried.isEmpty ? "nowhere" : tried)). "
                + "Run Scripts/build-shims.sh and point EIDER_SHIMS_DIR at build/shims, or reinstall Eider."
        )
    }
}
