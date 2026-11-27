import Foundation
import XCTest
@testable import EiderInstall

final class LocalInstallerTests: XCTestCase {
    private var keychain: TemporaryKeychain!
    private var authority: LocalRootAuthority!
    private var session: URLSession!
    private var ipa: URL!
    private var ipaData: Data!

    override func setUp() async throws {
        keychain = try TemporaryKeychain()
        authority = LocalRootAuthority(namespace: "test.eider.installer", keychain: keychain.scope)
        session = PinnedRootDelegate.session(rootDER: try await authority.rootCertificate())
        ipaData = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        ipa = keychain.directory.appendingPathComponent("signed.ipa")
        try ipaData.write(to: ipa)
    }

    override func tearDown() {
        session?.invalidateAndCancel()
        keychain?.delete()
    }

    /// Counts background activity begins and ends.
    private actor ActivityLog {
        var begun = 0
        var ended = 0
        func begin() { begun += 1 }
        func end() { ended += 1 }
    }

    private func activity(_ log: ActivityLog) -> BackgroundActivity {
        BackgroundActivity { _ in
            await log.begin()
            return { await log.end() }
        }
    }

    /// Does what iOS did on the device: fetch the manifest, then HEAD and GET the IPA.
    private func iOSStandIn(fetched: @escaping @Sendable (Data) -> Void) -> LocalInstaller.Opener {
        let session = self.session!
        return { link in
            guard link.scheme == "itms-services",
                  let query = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
                  query.first(where: { $0.name == "action" })?.value == "download-manifest",
                  let manifestString = query.first(where: { $0.name == "url" })?.value,
                  let manifestURL = URL(string: manifestString) else { return false }
            // A failure here shows up as the test's unfulfilled "IPA received" expectation.
            _ = Task {
                let (manifest, _) = try await session.data(from: manifestURL)
                let plist = try PropertyListSerialization.propertyList(from: manifest, format: nil) as? [String: Any]
                let item = (plist?["items"] as? [[String: Any]])?.first
                let asset = (item?["assets"] as? [[String: Any]])?.first
                let ipaURL = URL(string: asset?["url"] as? String ?? "")!
                var head = URLRequest(url: ipaURL)
                head.httpMethod = "HEAD"
                _ = try await session.data(for: head)
                let (body, _) = try await session.data(from: ipaURL)
                fetched(body)
            }
            return true
        }
    }

    func testInstallHandsTheIPAToTheStandIn() async throws {
        let log = ActivityLog()
        let received = expectation(description: "IPA received")
        let box = DataBox()
        let installer = LocalInstaller(authority: authority, opener: iOSStandIn { data in
            box.data = data
            received.fulfill()
        }, background: activity(log), grace: 0.2)

        let stream = try await installer.install(ipa: ipa, bundleID: "org.example.demo", version: "1.0",
                                                 title: "Demo")
        var progress: [InstallProgress] = []
        for try await step in stream { progress.append(step) }
        await fulfillment(of: [received], timeout: 10)

        XCTAssertEqual(box.data, ipaData)
        guard case .serving(let manifest) = progress.first else { return XCTFail("\(progress)") }
        XCTAssertEqual(manifest.host, "127.0.0.1")
        guard case .opened(let link) = progress.dropFirst().first else { return XCTFail("\(progress)") }
        XCTAssertTrue(link.absoluteString.hasPrefix("itms-services://?action=download-manifest&url=https%3A%2F%2F127.0.0.1%3A"))
        XCTAssertTrue(progress.contains(.manifestFetched))
        XCTAssertTrue(progress.contains(.downloading(sent: Int64(ipaData.count), total: Int64(ipaData.count))))
        XCTAssertEqual(progress.last, .handedToIOS)

        // After the grace period the server stops and the background activity ends.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let begun = await log.begun
        let ended = await log.ended
        XCTAssertEqual(begun, 1)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(tcpConnect(host: "127.0.0.1", port: manifest.port!), ECONNREFUSED)
    }

    func testInstallThrowsWhenTheLinkCannotBeOpened() async throws {
        let log = ActivityLog()
        let installer = LocalInstaller(authority: authority, opener: { _ in false }, background: activity(log))
        do {
            _ = try await installer.install(ipa: ipa, bundleID: "a", version: "1", title: "A")
            XCTFail("expected couldNotOpen")
        } catch LocalInstaller.Error.couldNotOpen(let link) {
            XCTAssertEqual(link.scheme, "itms-services")
        }
        let ended = await log.ended
        XCTAssertEqual(ended, 1)
    }

    func testInstallTimesOutWhenIOSNeverFetches() async throws {
        let installer = LocalInstaller(authority: authority, opener: { _ in true }, background: .none, timeout: 1)
        let stream = try await installer.install(ipa: ipa, bundleID: "a", version: "1", title: "A")
        do {
            for try await _ in stream {}
            XCTFail("expected timedOut")
        } catch let error as LocalInstaller.Error {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testOpenProfileInstallServesTheProfile() async throws {
        let opened = expectation(description: "opened")
        let installer = LocalInstaller(authority: authority, opener: { url in
            opened.fulfill()
            return url.scheme == "http"
        }, background: .none, grace: 0.2)
        let url = try await installer.openProfileInstall()
        await fulfillment(of: [opened], timeout: 5)
        let plain = URLSession(configuration: .ephemeral)
        defer { plain.invalidateAndCancel() }
        let (data, _) = try await plain.data(from: url)
        let expected = try await authority.mobileconfig()
        XCTAssertEqual(data, expected)
    }

    func testOnMacTheDefaultOpenerRefuses() async throws {
        let installer = LocalInstaller(authority: authority, background: BackgroundActivity.none)
        do {
            _ = try await installer.install(ipa: ipa, bundleID: "a", version: "1", title: "A")
            XCTFail("expected couldNotOpen")
        } catch LocalInstaller.Error.couldNotOpen {}
    }
}

private final class DataBox: @unchecked Sendable {
    var data: Data?
}
