import XCTest
@testable import EiderKit

/// Opt-in: `EIDER_LIVE_SOURCES=https://a/source.json,https://b/apps.json swift test --filter CatalogLive`.
/// Reports what the real parser makes of real sources; nothing is saved.
final class CatalogLiveTests: XCTestCase {
    func testLiveSources() async throws {
        let raw = ProcessInfo.processInfo.environment["EIDER_LIVE_SOURCES"] ?? ""
        let urls = raw.split(separator: ",").compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        try XCTSkipIf(urls.isEmpty, "set EIDER_LIVE_SOURCES to run")

        for url in urls {
            do {
                let data = try await SourceFetcher.default(url)
                let source = try SourceParser.parse(data: data, from: url)
                let versions = source.apps.reduce(0) { $0 + $1.versions.count }
                print("LIVE \(url.absoluteString): \(source.format) \"\(source.name)\" "
                    + "apps=\(source.apps.count) versions=\(versions) news=\(source.news.count) "
                    + "warnings=\(source.warnings.count) bytes=\(data.count)")
                for line in source.warnings.prefix(5) { print("LIVE   warning: \(line)") }
            } catch {
                print("LIVE \(url.absoluteString): FAILED \(error)")
                XCTFail("\(url.absoluteString): \(error)")
            }
        }
    }
}
