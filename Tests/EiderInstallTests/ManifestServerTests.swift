import Foundation
import XCTest
@testable import EiderInstall

final class ManifestServerTests: XCTestCase {
    private let wifi = LocalNetwork.InterfaceAddress(interface: "en0", bytes: [192, 168, 1, 50])

    func testValidateAcceptsAnHTTPSAddressOnAnotherHost() throws {
        let url = try ManifestServer.validate("  https://192.168.1.117:8443/eider/manifest/s3cret.plist\n",
                                              ownAddresses: [wifi])
        XCTAssertEqual(url.absoluteString, "https://192.168.1.117:8443/eider/manifest/s3cret.plist")
        XCTAssertNoThrow(try ManifestServer.validate("https://manifests.example/m.plist?k=1", ownAddresses: [wifi]))
    }

    func testValidateRefusesWhatAppstoredWouldRefuse() {
        func error(_ text: String) -> ManifestServer.Invalid? {
            do {
                _ = try ManifestServer.validate(text, ownAddresses: [wifi])
                return nil
            } catch {
                return error as? ManifestServer.Invalid
            }
        }
        XCTAssertEqual(error(""), .notAURL)
        XCTAssertEqual(error("manifest server"), .notAURL)
        XCTAssertEqual(error("https://"), .notAURL)
        XCTAssertEqual(error("http://192.168.1.117:8080/m.plist"), .notHTTPS)
        XCTAssertEqual(error("https://192.168.1.117/m.plist#x"), .hasFragment)
        // "The manifest URL isn't external": loopback and the iPhone's own Wi-Fi address.
        XCTAssertEqual(error("https://127.0.0.1:8443/m.plist"), .onThisDevice("127.0.0.1"))
        XCTAssertEqual(error("https://localhost/m.plist"), .onThisDevice("localhost"))
        XCTAssertEqual(error("https://[::1]/m.plist"), .onThisDevice("[::1]"))
        XCTAssertEqual(error("https://192.168.1.50:8443/m.plist"), .onThisDevice("192.168.1.50"))
    }

    func testManifestURLAppendsToAnExistingQuery() throws {
        let ipa = URL(string: "https://192.168.1.50:1/0123456789abcdef0123456789abcdef/app.ipa")!
        let url = try XCTUnwrap(ManifestServer.manifestURL(
            base: URL(string: "https://h.example/m?key=abc")!, bundleID: "a.b", version: "1", title: "A", ipa: ipa))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://h.example/m?key=abc&bundle=a.b&version=1&title=A&url="),
                      url.absoluteString)
    }

    /// `CharacterSet.alphanumerics` would let these through unencoded.
    func testManifestURLEncodesNonASCIIAndReservedCharacters() throws {
        let ipa = URL(string: "https://192.168.1.50:1/0123456789abcdef0123456789abcdef/app.ipa")!
        let url = try XCTUnwrap(ManifestServer.manifestURL(
            base: URL(string: "https://h.example/m.plist")!, bundleID: "a.b", version: "1.0+2",
            title: "Caf\u{00E9} & Co/2", ipa: ipa))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "Caf\u{00E9} & Co/2")
        XCTAssertEqual(items.first { $0.name == "version" }?.value, "1.0+2")
        XCTAssertTrue(url.absoluteString.contains("title=Caf%C3%A9%20%26%20Co%2F2"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("version=1.0%2B2"), url.absoluteString)
    }

    func testMaskedHidesThePathAndQuery() {
        XCTAssertEqual(ManifestServer.masked(URL(string: "https://192.168.1.117:8443/eider/manifest/s3cret.plist")!),
                       "https://192.168.1.117:8443/\u{2022}\u{2022}\u{2022}\u{2022}.plist")
        XCTAssertEqual(ManifestServer.masked(URL(string: "https://h.example/m?key=abc")!),
                       "https://h.example/\u{2022}\u{2022}\u{2022}\u{2022}?\u{2022}\u{2022}\u{2022}\u{2022}")
        XCTAssertEqual(ManifestServer.masked(URL(string: "https://h.example")!), "https://h.example")
    }

    func testOnly200And400CountAsReachable() {
        XCTAssertEqual(ManifestServer.reachability(forStatus: 200), .reachable)
        XCTAssertEqual(ManifestServer.reachability(forStatus: 400), .reachable)
        XCTAssertEqual(ManifestServer.reachability(forStatus: 404), .unexpectedStatus(404))
        XCTAssertEqual(ManifestServer.reachability(forStatus: 500), .unexpectedStatus(500))
    }

    /// A plain-HTTP loopback server stands in for the manifest server; the probe itself does not
    /// care about the scheme (validation does).
    func testProbeTellsAnAnsweringServerFromAWrongPathAndFromNoServer() async throws {
        let server = LocalHTTPServer(identity: nil) { request in
            request.path == "/eider/manifest/s3cret.plist" ? .data(Data("<plist/>".utf8), contentType: "text/xml") : nil
        }
        let port = try await server.start()
        let good = await ManifestServer.probe(URL(string: "http://127.0.0.1:\(port)/eider/manifest/s3cret.plist")!)
        XCTAssertEqual(good, .reachable)
        let wrongSecret = await ManifestServer.probe(URL(string: "http://127.0.0.1:\(port)/eider/manifest/nope.plist")!)
        XCTAssertEqual(wrongSecret, .unexpectedStatus(404))
        server.stop()

        let gone = await ManifestServer.probe(URL(string: "http://127.0.0.1:\(port)/eider/manifest/s3cret.plist")!)
        guard case .unreachable = gone else { return XCTFail("\(gone)") }
    }

    func testProbeQueryLooksLikeARealInstall() throws {
        let url = try XCTUnwrap(ManifestServer.probeURL(base: URL(string: "https://h.example/m.plist")!))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["bundle", "version", "title", "url"])
        let ipa = try XCTUnwrap(items.last?.value.flatMap(URL.init(string:)))
        XCTAssertEqual(ipa.scheme, "https")
        XCTAssertNotNil(ipa.path.range(of: "^/[0-9a-f]{32}/app\\.ipa$", options: .regularExpression), ipa.path)
    }
}
