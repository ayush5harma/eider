import Darwin
import Foundation
import XCTest
@testable import EiderInstall

final class LocalInstallServerTests: XCTestCase {
    private var keychain: TemporaryKeychain!
    private var authority: LocalRootAuthority!
    private var identity: ServerIdentity!
    private var ipa: URL!
    private var ipaData: Data!
    private var session: URLSession!
    /// This Mac's own LAN address, standing in for the iPhone's Wi-Fi address.
    private var address: DeviceAddress!
    /// The manifest server, on another host: appstored refuses a manifest the iPhone serves.
    private let manifestBase = URL(string: "https://manifests.example:8443/eider/manifest/s3cret.plist")!

    override func setUp() async throws {
        address = try macInstallAddress()
        keychain = try TemporaryKeychain()
        authority = LocalRootAuthority(namespace: "test.eider.server", keychain: keychain.scope)
        identity = try await authority.serverIdentity(for: [address])
        // Three chunks and a bit, so a full GET crosses chunk boundaries.
        ipaData = Data((0..<(3 * 512 * 1024 + 1234)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        ipa = keychain.directory.appendingPathComponent("app.ipa")
        try ipaData.write(to: ipa)
        session = PinnedRootDelegate.session(rootDER: identity.root)
    }

    override func tearDown() {
        session?.invalidateAndCancel()
        keychain?.delete()
    }

    private func request(_ url: URL, method: String = "GET", range: String? = nil,
                         using session: URLSession? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = method
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await (session ?? self.session).data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private func collect(_ events: AsyncStream<LocalInstallServer.Event>) async -> [LocalInstallServer.Event] {
        var all: [LocalInstallServer.Event] = []
        for await event in events { all.append(event) }
        return all
    }

    func testServesTheIPAWithHeadAndRangesAndNamesItInTheManifestServerURL() async throws {
        let server = try LocalInstallServer(identity: identity.identity, address: address, manifestBase: manifestBase,
                                            ipa: ipa, bundleID: "org.example.demo", version: "1.2.3", title: "Demo & Co")
        let manifestURL = try await server.start()
        let ipaURL = try XCTUnwrap(server.ipaURL)
        // The manifest comes from the manifest server; the IPA from this device's LAN address.
        XCTAssertEqual(ipaURL.host, address.description)
        XCTAssertEqual(ipaURL.scheme, "https")
        XCTAssertEqual(ipaURL.path, "/\(server.token)/app.ipa")
        XCTAssertNotNil(server.token.range(of: "^[0-9a-f]{32}$", options: .regularExpression), server.token)
        XCTAssertTrue(manifestURL.absoluteString.hasPrefix(manifestBase.absoluteString + "?"), manifestURL.absoluteString)
        let query = try XCTUnwrap(URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.map(\.name), ["bundle", "version", "title", "url"])
        XCTAssertEqual(query.map(\.value), ["org.example.demo", "1.2.3", "Demo & Co", ipaURL.absoluteString])
        XCTAssertEqual(server.manifestURL, manifestURL)

        // The old local manifest route is gone: appstored refused it as not external.
        let (_, local) = try await request(ipaURL.deletingLastPathComponent().appendingPathComponent("manifest.plist"))
        XCTAssertEqual(local.statusCode, 404)

        let (headBody, head) = try await request(ipaURL, method: "HEAD")
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(headBody.isEmpty)
        XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Length"), String(ipaData.count))
        XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(head.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")

        let (part, partial) = try await request(ipaURL, range: "bytes=100-199")
        XCTAssertEqual(partial.statusCode, 206)
        XCTAssertEqual(partial.value(forHTTPHeaderField: "Content-Range"), "bytes 100-199/\(ipaData.count)")
        XCTAssertEqual(part, ipaData.subdata(in: 100..<200))

        let (tail, tailResponse) = try await request(ipaURL, range: "bytes=\(ipaData.count)-")
        XCTAssertEqual(tailResponse.statusCode, 416)
        XCTAssertFalse(tail.isEmpty)

        let (whole, full) = try await request(ipaURL)
        XCTAssertEqual(full.statusCode, 200)
        XCTAssertEqual(whole, ipaData)

        server.stop()
        let events = await collect(server.events)
        XCTAssertEqual(events.first, .manifestFetched)
        XCTAssertTrue(events.contains(.ipaFullyServed), "\(events)")
        XCTAssertEqual(events.filter { $0 == .ipaFullyServed }.count, 1)
        XCTAssertEqual(events.last, .stopped)
        XCTAssertTrue(events.contains(.ipaBytesServed(sent: Int64(ipaData.count), total: Int64(ipaData.count))))
    }

    func testRangesThatTogetherCoverTheIPACountAsFullyServed() async throws {
        let server = try LocalInstallServer(identity: identity.identity, address: address, manifestBase: manifestBase, ipa: ipa, bundleID: "a", version: "1",
                                            title: "A")
        try await server.start()
        let ipaURL = try XCTUnwrap(server.ipaURL)
        let half = ipaData.count / 2
        _ = try await request(ipaURL, range: "bytes=\(half)-")
        _ = try await request(ipaURL, range: "bytes=0-\(half - 1)")
        server.stop()
        let events = await collect(server.events)
        XCTAssertTrue(events.contains(.ipaFullyServed), "\(events)")
        XCTAssertEqual(events.filter { $0 == .manifestFetched }.count, 1, "\(events)")
    }

    func testUnknownTokenAndPathsAre404() async throws {
        let server = try LocalInstallServer(identity: identity.identity, address: address, manifestBase: manifestBase, ipa: ipa, bundleID: "a", version: "1",
                                            title: "A")
        try await server.start()
        defer { server.stop() }
        let ipaURL = try XCTUnwrap(server.ipaURL)
        let base = try XCTUnwrap(URL(string: "https://\(address!):\(ipaURL.port!)"))
        for path in ["/0123456789abcdef0123456789abcdef/app.ipa", "/\(server.token)/manifest.plist",
                     "/\(server.token)/other", "/\(server.token)", "/", "/root.mobileconfig"] {
            let (_, response) = try await request(base.appendingPathComponent(path))
            XCTAssertEqual(response.statusCode, 404, path)
        }
        let (_, post) = try await request(ipaURL, method: "POST")
        XCTAssertEqual(post.statusCode, 405)
    }

    func testListensOnTheGivenAddressOnly() async throws {
        let server = try LocalInstallServer(identity: identity.identity, address: address, manifestBase: manifestBase, ipa: ipa, bundleID: "a",
                                            version: "1", title: "A")
        try await server.start()
        let port = try XCTUnwrap(server.ipaURL?.port)
        defer { server.stop() }
        XCTAssertEqual(tcpConnect(host: address.description, port: port), 0)
        XCTAssertEqual(tcpConnect(host: "127.0.0.1", port: port), ECONNREFUSED)
    }

    /// Another machine on the Wi-Fi cannot be simulated from one Mac, so the server is told
    /// that only loopback is this device: a connection from the Mac's LAN address then looks
    /// like a stranger's and must get no answer at all.
    func testConnectionsFromOtherAddressesAreRefused() async throws {
        let server = try LocalInstallServer(identity: identity.identity, address: address, manifestBase: manifestBase, ownAddresses: { [] },
                                            ipa: ipa, bundleID: "a", version: "1", title: "A", timeout: 60)
        try await server.start()
        let ipaURL = try XCTUnwrap(server.ipaURL)
        do {
            let (_, response) = try await request(ipaURL)
            XCTFail("A connection from \(address!) outside the device was answered: \(response.statusCode)")
        } catch let error as URLError {
            XCTAssertTrue([.networkConnectionLost, .secureConnectionFailed, .cannotConnectToHost,
                           .cannotParseResponse, .badServerResponse].contains(error.code), "\(error)")
        }
        server.stop()
        let events = await collect(server.events)
        XCTAssertEqual(events, [.stopped])
    }

    func testUntrustedRootIsRejectedByDefaultTrust() async throws {
        let server = try LocalInstallServer(identity: identity.identity, address: address, manifestBase: manifestBase, ipa: ipa, bundleID: "a", version: "1",
                                            title: "A")
        try await server.start()
        defer { server.stop() }
        let ipaURL = try XCTUnwrap(server.ipaURL)
        let plain = URLSession(configuration: .ephemeral)
        defer { plain.invalidateAndCancel() }
        do {
            _ = try await request(ipaURL, using: plain)
            XCTFail("The default trust accepted a root nobody trusted.")
        } catch let error as URLError {
            XCTAssertTrue([.serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasUnknownRoot,
                           .cancelled].contains(error.code), "\(error)")
        }
    }

    func testProfileServerServesOnlyTheMobileconfigOverHTTP() async throws {
        let profile = try await authority.mobileconfig()
        let server = LocalProfileServer(mobileconfig: profile)
        let url = try await server.start()
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/root.mobileconfig")

        let plain = URLSession(configuration: .ephemeral)
        defer { plain.invalidateAndCancel() }
        let (data, response) = try await request(url, using: plain)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/x-apple-aspen-config")
        XCTAssertEqual(data, profile)
        let (_, missing) = try await request(url.deletingLastPathComponent().appendingPathComponent("x"),
                                             using: plain)
        XCTAssertEqual(missing.statusCode, 404)

        server.stop()
        var events: [LocalProfileServer.Event] = []
        for await event in server.events { events.append(event) }
        XCTAssertEqual(events, [.profileFetched, .stopped])
    }

    func testStatus() async throws {
        let fresh = LocalRootAuthority(namespace: "test.eider.fresh", keychain: keychain.scope)
        let notSetUp = await fresh.status()
        XCTAssertEqual(notSetUp, .notSetUp)
        // The default trust on this Mac does not know the root.
        let untrusted = await authority.status()
        XCTAssertEqual(untrusted, .needsTrust)
        // Standing in for a device where the user trusted the root.
        let trusted = await authority.status(probeWith: session, address: address)
        XCTAssertEqual(trusted, .ready)
        // No Wi-Fi: nothing appstored would take.
        let offline = await authority.status(probeWith: session, address: nil)
        XCTAssertEqual(offline, .needsWiFi)
    }

    func testProbeTellsAnUntrustedRootFromNoConnection() {
        XCTAssertEqual(LocalRootAuthority.classify(URLError(.serverCertificateUntrusted)), .untrusted)
        XCTAssertEqual(LocalRootAuthority.classify(URLError(.secureConnectionFailed)), .untrusted)
        XCTAssertEqual(LocalRootAuthority.classify(URLError(.notConnectedToInternet)), .unreachable)
        XCTAssertEqual(LocalRootAuthority.classify(URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(LocalRootAuthority.classify(URLError(.timedOut)), .unreachable)
    }

    func testItmsServicesURLPercentEncodesTheManifestURL() {
        let manifest = URL(string: "https://127.0.0.1:50123/abc/manifest.plist")!
        XCTAssertEqual(
            LocalInstallServer.itmsServicesURL(manifest: manifest)?.absoluteString,
            "itms-services://?action=download-manifest&url=https%3A%2F%2F127.0.0.1%3A50123%2Fabc%2Fmanifest.plist")
    }

    /// The manifest server's URL goes into the link encoded once more, so its own encoded query
    /// values (the IPA URL among them) arrive at the manifest server intact.
    func testItmsServicesLinkForTheManifestServer() throws {
        let ipa = URL(string: "https://192.168.1.50:61901/0123456789abcdef0123456789abcdef/app.ipa")!
        let manifest = try XCTUnwrap(ManifestServer.manifestURL(
            base: URL(string: "https://192.168.1.117:8443/eider/manifest/s3cret.plist")!,
            bundleID: "com.example.app", version: "2.2.0", title: "iTorrent Beta", ipa: ipa))
        XCTAssertEqual(
            manifest.absoluteString,
            "https://192.168.1.117:8443/eider/manifest/s3cret.plist?bundle=com.example.app&version=2.2.0"
                + "&title=iTorrent%20Beta&url=https%3A%2F%2F192.168.1.50%3A61901%2F0123456789abcdef0123456789abcdef%2Fapp.ipa")
        let link = try XCTUnwrap(LocalInstallServer.itmsServicesURL(manifest: manifest))
        XCTAssertEqual(
            link.absoluteString,
            "itms-services://?action=download-manifest&url=https%3A%2F%2F192.168.1.117%3A8443%2Feider%2Fmanifest%2Fs3cret.plist"
                + "%3Fbundle%3Dcom.example.app%26version%3D2.2.0%26title%3DiTorrent%2520Beta%26url%3Dhttps%253A%252F%252F"
                + "192.168.1.50%253A61901%252F0123456789abcdef0123456789abcdef%252Fapp.ipa")
        // What iOS reads back out of the link is the manifest URL, unchanged.
        let decoded = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "url" }?.value
        XCTAssertEqual(decoded, manifest.absoluteString)
    }
}

/// 0 when a TCP connection succeeds, else errno.
func tcpConnect(host: String, port: Int) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    inet_pton(AF_INET, host, &address.sin_addr)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0 ? 0 : errno
}
