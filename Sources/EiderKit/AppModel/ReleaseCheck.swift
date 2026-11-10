import Foundation

public enum ReleaseCheckState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(current: String)
    case newer(version: String, url: URL)
    case failed(String)
}

/// The "Check for Updates..." request: one GET, only when the person chooses it.
public struct ReleaseCheck: Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/ayush5harma/eider/releases/latest")!

    private let fetch: SourceFetch
    private let current: String

    /// `SourceFetcher.default` is reused for its https-only policy, size cap and
    /// timeouts; the response is small JSON like a source's.
    public init(fetch: @escaping SourceFetch = SourceFetcher.default, current: String = EiderVersion.current) {
        self.fetch = fetch
        self.current = current
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    public func run() async -> ReleaseCheckState {
        do {
            let release = try JSONDecoder().decode(Release.self, from: try await fetch(Self.latestReleaseURL))
            let tag = release.tag_name.trimmingCharacters(in: .whitespaces)
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard AppVersion.isNewer(version: version, build: nil, than: current, build: nil) else {
                return .upToDate(current: current)
            }
            // The link is shown to the person and opened on a click; only a
            // GitHub address is accepted so a hostile response cannot aim it elsewhere.
            guard release.html_url.scheme == "https", release.html_url.host == "github.com" else {
                return .failed("The release answer pointed somewhere other than GitHub, so Eider ignored it.")
            }
            return .newer(version: version, url: release.html_url)
        } catch is CancellationError {
            return .idle
        } catch {
            let failure = OperationFailure.wrap(error)
            return .failed("Could not check for updates: \(failure.message)")
        }
    }
}
