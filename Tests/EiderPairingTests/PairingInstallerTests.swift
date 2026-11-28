import CryptoKit
import Foundation
import XCTest
@testable import EiderPairing

/// Offline tests: they go through the C library, but never reach a device.
final class PairingInstallerTests: XCTestCase {
    /// A pairing file from fresh keys and a random identifier, known to no device.
    static func freshPairingFile() throws -> RemotePairingFile {
        let key = Curve25519.Signing.PrivateKey()
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["private_key": key.rawRepresentation,
                               "public_key": key.publicKey.rawRepresentation,
                               "identifier": UUID().uuidString],
            format: .xml, options: 0)
        return try RemotePairingFile(data: data)
    }

    /// A loopback port nothing listens on: bind, read the port, close.
    private func closedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                guard Darwin.bind(fd, raw, length) == 0, getsockname(fd, raw, &length) == 0 else {
                    throw POSIXError(.EADDRINUSE)
                }
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    func testCheckReportsUnreachableWhenNothingListens() async throws {
        let installer = PairingInstaller(pairingFile: try Self.freshPairingFile(),
                                         host: "127.0.0.1", port: try closedPort())
        let start = Date()
        let result = await installer.check()
        guard case .unreachable(let detail) = result else {
            return XCTFail("expected unreachable, got \(result)")
        }
        XCTAssertTrue(detail.contains("127.0.0.1"), detail)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCheckReportsUnreachableForAHostName() async throws {
        // The C side takes IP literals only; a name is a caller error, reported, not crashed on.
        let installer = PairingInstaller(pairingFile: try Self.freshPairingFile(), host: "iphone.local")
        guard case .refused(let detail) = await installer.check() else {
            return XCTFail("a host name must not be reported as ready or unreachable")
        }
        XCTAssertTrue(detail.contains("not an IP address"), detail)
    }

    func testInstallRefusesAMissingIPABeforeConnecting() async throws {
        let installer = PairingInstaller(pairingFile: try Self.freshPairingFile(), host: "127.0.0.1", port: try closedPort())
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID()).ipa")
        do {
            try await installer.install(ipa: missing, bundleID: "a.b") { _ in }
            XCTFail("expected an error")
        } catch PairingInstallError.ipaUnreadable {
        }
    }

    func testInstallReportsConnectingThenUnreachable() async throws {
        let ipa = FileManager.default.temporaryDirectory.appendingPathComponent("eider-\(UUID()).ipa")
        try Data("PK".utf8).write(to: ipa)
        defer { try? FileManager.default.removeItem(at: ipa) }
        let installer = PairingInstaller(pairingFile: try Self.freshPairingFile(), host: "127.0.0.1", port: try closedPort())
        let seen = Recorder()
        do {
            try await installer.install(ipa: ipa, bundleID: "a.b") { seen.append($0) }
            XCTFail("expected an error")
        } catch PairingInstallError.unreachable {
        }
        XCTAssertEqual(seen.values, [.connecting])
    }

    func testBundleIDWithSlashIsRefused() async throws {
        let installer = PairingInstaller(pairingFile: try Self.freshPairingFile())
        do {
            try await installer.uninstall(bundleID: "../x")
            XCTFail("expected an error")
        } catch PairingInstallError.installFailed {
        }
    }

    func testErrorMessagesAreUserFacing() {
        XCTAssertTrue(PairingInstallError.unreachable("x").localizedDescription.contains("LocalDevVPN"))
        XCTAssertTrue(PairingInstallError.pairingRejected("x").localizedDescription.contains("pairing file"))
        XCTAssertEqual(PairingInstaller.error(code: 5, detail: "d"), .pairingRejected("d"))
        XCTAssertEqual(PairingInstaller.error(code: 3, detail: "d"), .unreachable("d"))
        XCTAssertEqual(PairingInstaller.error(code: 10, detail: "d"), .installFailed("d"))
        XCTAssertEqual(PairingInstaller.error(code: 99, detail: "d"), .internalError("d"))
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PairingInstallProgress] = []
    func append(_ value: PairingInstallProgress) { lock.withLock { stored.append(value) } }
    var values: [PairingInstallProgress] { lock.withLock { stored } }
}
