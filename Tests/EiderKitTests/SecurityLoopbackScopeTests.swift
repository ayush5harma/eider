import Foundation
import XCTest
@testable import EiderKit

/// Finding 8: http loopback is only for a source the user added by a loopback
/// URL and the items inside it; never from an https source, never from a link.
final class SecurityLoopbackScopeTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    private func parse(_ json: String, from source: String) throws -> CatalogSource {
        try SourceParser.parse(data: Data(json.utf8), from: URL(string: source)!)
    }

    private let altStore = #"""
    {"name":"S","apps":[
      {"name":"Loop","bundleIdentifier":"com.loop","iconURL":"http://127.0.0.1:9/i.png","versions":[{"version":"1","downloadURL":"http://127.0.0.1:9/a.ipa"}]},
      {"name":"Rel","bundleIdentifier":"com.rel","versions":[{"version":"1","downloadURL":"/b.ipa"}]},
      {"name":"Web","bundleIdentifier":"com.web","versions":[{"version":"1","downloadURL":"https://cdn.example.com/c.ipa"}]}
    ]}
    """#

    func testHTTPSSourceDoesNotGetLoopbackItems() throws {
        let source = try parse(altStore, from: "https://example.com/s.json")
        XCTAssertEqual(source.apps.map(\.bundleID), ["com.rel", "com.web"], "the loopback item is dropped")
        XCTAssertTrue(source.warnings.contains { $0.contains("com.loop") && $0.contains("download address") }, "\(source.warnings)")
    }

    func testLoopbackSourceKeepsItsLoopbackItems() throws {
        let source = try parse(altStore, from: "http://127.0.0.1:9/s.json")
        XCTAssertEqual(source.apps.map(\.bundleID), ["com.loop", "com.rel", "com.web"])
        XCTAssertEqual(source.apps[0].versions[0].downloadURL.absoluteString, "http://127.0.0.1:9/a.ipa")
        XCTAssertEqual(source.apps[1].versions[0].downloadURL.absoluteString, "http://127.0.0.1:9/b.ipa")
    }

    func testPolicyNeedsTheFlagForLoopback() throws {
        let local = try XCTUnwrap(URL(string: "http://localhost:8000/x"))
        XCTAssertFalse(URLPolicy.isAllowed(local))
        XCTAssertTrue(URLPolicy.isAllowed(local, allowLoopback: true))
        XCTAssertNil(URLPolicy.resolve("http://127.0.0.1/a", against: nil, allowFile: false))
        XCTAssertNotNil(URLPolicy.resolve("http://127.0.0.1/a", against: nil, allowFile: false, allowLoopback: true))
        XCTAssertTrue(URLPolicy.isAllowed(try XCTUnwrap(URL(string: "https://example.com/x"))))
    }

    func testDeepLinksNeverCarryLoopback() throws {
        for text in ["eider://source/http://localhost:8000/repo.json", "eider://install/http://127.0.0.1:8000/a.ipa", "eider://install/http%3A%2F%2F127.0.0.1%2Fa.ipa"] {
            XCTAssertNil(DeepLink.parse(try XCTUnwrap(URL(string: text))), text)
        }
        XCTAssertEqual(
            DeepLink.parse(try XCTUnwrap(URL(string: "eider://source/https://example.com/repo.json"))),
            .addSource(try XCTUnwrap(URL(string: "https://example.com/repo.json"))))
    }

    func testRedirectFromHTTPSToLoopbackIsRefused() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        StubURLProtocol.handler = { _ in .init(status: 302, redirectTo: URL(string: "http://127.0.0.1:9/a.ipa")!) }
        let release = CatalogVersion(version: "1", downloadURL: URL(string: "https://cdn.example.com/a.ipa")!)
        let app = CatalogApp(bundleID: "com.x", name: "X", versions: [release])
        let manager = DownloadManager(paths: paths, configuration: StubURLProtocol.configuration())
        do {
            for try await _ in manager.download(release, of: app) {}
            XCTFail("the redirect to loopback should have been refused")
        } catch {
            XCTAssertEqual(error as? DownloadFailure, .blockedURL("http://127.0.0.1:9/a.ipa"))
        }
    }

    func testLoopbackDownloadFromAnHTTPSSourceIsRefusedBeforeAnyRequest() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        let library = LibraryStore(paths: paths)
        let operations = AppOperations(
            sources: SourceStore(paths: paths), library: library,
            downloads: DownloadManager(paths: paths, configuration: StubURLProtocol.configuration()),
            installIPA: { _, _, _ in XCTFail("nothing should be installed"); throw CancellationError() },
            uninstaller: Uninstaller(store: library))
        let release = CatalogVersion(version: "1", downloadURL: URL(string: "http://127.0.0.1:9/a.ipa")!)
        let app = CatalogApp(bundleID: "com.x", name: "X", versions: [release])
        let remote = CatalogSource(url: URL(string: "https://example.com/s.json")!, format: .altStore, name: "S", apps: [app])
        do {
            _ = try await operations.install(app: app, from: remote)
            XCTFail("expected a refusal")
        } catch let failure as OperationFailure {
            XCTAssertEqual(failure.code, "operations.bad_url")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}
