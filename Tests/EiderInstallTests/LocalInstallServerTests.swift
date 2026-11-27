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

    override func setUp() async throws {
        keychain = try TemporaryKeychain()
        authority = LocalRootAuthority(namespace: "test.eider.server", keychain: keychain.scope)
        identity = try await authority.serverIdentity()
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

    func testServesManifestAndIPAWithHeadAndRanges() async throws {
        let server = try LocalInstallServer(identity: identity.identity, ipa: ipa, bundleID: "org.example.demo",
                                            version: "1.2.3", title: "Demo & Co")
        let manifestURL = try await server.start()
        let ipaURL = try XCTUnwrap(server.ipaURL)
        XCTAssertEqual(manifestURL.host, "127.0.0.1")
        XCTAssertEqual(manifestURL.lastPathComponent, "manifest.plist")
        XCTAssertEqual(server.token.count, 32)

        let (manifestData, manifestResponse) = try await request(manifestURL)
        XCTAssertEqual(manifestResponse.statusCode, 200)
        let manifest = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: manifestData, format: nil) as? [String: Any])
        let item = try XCTUnwrap((manifest["items"] as? [[String: Any]])?.first)
        let asset = try XCTUnwrap((item["assets"] as? [[String: Any]])?.first)
        XCTAssertEqual(asset["kind"] as? String, "software-package")
        XCTAssertEqual(asset["url"] as? String, ipaURL.absoluteString)
        let metadata = try XCTUnwrap(item["metadata"] as? [String: String])
        XCTAssertEqual(metadata, ["bundle-identifier": "org.example.demo", "bundle-version": "1.2.3",
                                  "kind": "software", "title": "Demo & Co"])

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
        let server = try LocalInstallServer(identity: identity.identity, ipa: ipa, bundleID: "a", version: "1",
                                            title: "A")
        try await server.start()
        let ipaURL = try XCTUnwrap(server.ipaURL)
        let half = ipaData.count / 2
        _ = try await request(ipaURL, range: "bytes=\(half)-")
        _ = try await request(ipaURL, range: "bytes=0-\(half - 1)")
        server.stop()
        let events = await collect(server.events)
        XCTAssertTrue(events.contains(.ipaFullyServed), "\(events)")
        XCTAssertFalse(events.contains(.manifestFetched))
    }

    func testUnknownTokenAndPathsAre404() async throws {
        let server = try LocalInstallServer(identity: identity.identity, ipa: ipa, bundleID: "a", version: "1",
                                            title: "A")
        let manifestURL = try await server.start()
        defer { server.stop() }
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(manifestURL.port!)"))
        for path in ["/0123456789abcdef0123456789abcdef/manifest.plist", "/\(server.token)/other",
                     "/\(server.token)", "/", "/root.mobileconfig"] {
            let (_, response) = try await request(base.appendingPathComponent(path))
            XCTAssertEqual(response.statusCode, 404, path)
        }
        let (_, post) = try await request(manifestURL, method: "POST")
        XCTAssertEqual(post.statusCode, 405)
    }

    func testListensOnLoopbackOnly() async throws {
        let server = try LocalInstallServer(identity: identity.identity, ipa: ipa, bundleID: "a", version: "1",
                                            title: "A")
        let port = try await server.start().port!
        defer { server.stop() }
        XCTAssertEqual(tcpConnect(host: "127.0.0.1", port: port), 0)
        guard let lan = firstNonLoopbackIPv4() else {
            throw XCTSkip("No non-loopback IPv4 address on this Mac.")
        }
        XCTAssertEqual(tcpConnect(host: lan, port: port), ECONNREFUSED, "reachable on \(lan)")
    }

    func testUntrustedRootIsRejectedByDefaultTrust() async throws {
        let server = try LocalInstallServer(identity: identity.identity, ipa: ipa, bundleID: "a", version: "1",
                                            title: "A")
        let manifestURL = try await server.start()
        defer { server.stop() }
        let plain = URLSession(configuration: .ephemeral)
        defer { plain.invalidateAndCancel() }
        do {
            _ = try await request(manifestURL, using: plain)
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
        let trusted = await authority.status(probeWith: session)
        XCTAssertEqual(trusted, .ready)
    }

    func testItmsServicesURLPercentEncodesTheManifestURL() {
        let manifest = URL(string: "https://127.0.0.1:50123/abc/manifest.plist")!
        XCTAssertEqual(
            LocalInstallServer.itmsServicesURL(manifest: manifest)?.absoluteString,
            "itms-services://?action=download-manifest&url=https%3A%2F%2F127.0.0.1%3A50123%2Fabc%2Fmanifest.plist")
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

func firstNonLoopbackIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let entry = pointer.pointee
        guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                       NI_NUMERICHOST) == 0 {
            return String(cString: host)
        }
    }
    return nil
}
