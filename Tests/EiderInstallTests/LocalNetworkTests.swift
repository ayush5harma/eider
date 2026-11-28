import Foundation
import Network
import XCTest
@testable import EiderInstall

final class LocalNetworkTests: XCTestCase {
    private typealias Address = LocalNetwork.InterfaceAddress

    private let loopback = Address(interface: "lo0", bytes: [127, 0, 0, 1], isLoopback: true)

    func testPrefersWiFiThenTheHotspotThenAnyPrivateAddress() {
        let wifi = Address(interface: "en0", bytes: [192, 168, 1, 40])
        let hotspot = Address(interface: "bridge100", bytes: [172, 20, 10, 1])
        let vpn = Address(interface: "utun2", bytes: [100, 71, 46, 91])

        XCTAssertEqual(LocalNetwork.installAddress(from: [loopback, vpn, hotspot, wifi])?.description, "192.168.1.40")
        XCTAssertEqual(LocalNetwork.installAddress(from: [loopback, vpn, hotspot])?.description, "172.20.10.1")
        XCTAssertEqual(LocalNetwork.installAddress(from: [loopback, vpn])?.interface, "utun2")
        XCTAssertEqual(LocalNetwork.installAddress(from: [Address(interface: "en0", bytes: [10, 1, 2, 3])])?.bytes,
                       [10, 1, 2, 3])
    }

    func testNoInstallAddressWithoutAPrivateNetwork() {
        let cellular = Address(interface: "pdp_ip0", bytes: [49, 36, 10, 2])
        let linkLocal = Address(interface: "en9", bytes: [169, 254, 98, 80])
        let wifiDown = Address(interface: "en0", bytes: [192, 168, 1, 40], isUp: false)
        let ipv6 = Address(interface: "en0", bytes: [0xFD] + [UInt8](repeating: 1, count: 15))
        XCTAssertNil(LocalNetwork.installAddress(from: [loopback, cellular, linkLocal, wifiDown, ipv6]))
        XCTAssertNil(LocalNetwork.installAddress(from: []))
    }

    func testPrivateRanges() {
        for private_ in [[10, 0, 0, 1], [172, 16, 0, 1], [172, 31, 255, 254], [192, 168, 0, 1], [100, 64, 0, 1],
                         [100, 127, 255, 254], [172, 20, 10, 2]] as [[UInt8]] {
            XCTAssertTrue(LocalNetwork.isPrivate(private_), "\(private_)")
        }
        for other in [[172, 32, 0, 1], [172, 15, 255, 255], [100, 128, 0, 1], [100, 63, 0, 1], [8, 8, 8, 8],
                      [127, 0, 0, 1], [169, 254, 1, 1], [192, 169, 0, 1]] as [[UInt8]] {
            XCTAssertFalse(LocalNetwork.isPrivate(other), "\(other)")
        }
    }

    func testConstraintBytesAreNetworkThenMask() {
        XCTAssertEqual(LocalNetwork.constraintBytes(network: [127, 0, 0, 1], prefix: 32),
                       [127, 0, 0, 1, 255, 255, 255, 255])
        XCTAssertEqual(LocalNetwork.constraintBytes(network: [172, 16, 0, 0], prefix: 12),
                       [172, 16, 0, 0, 255, 240, 0, 0])
        XCTAssertEqual(LocalNetwork.constraintBytes(network: [100, 64, 0, 0], prefix: 10),
                       [100, 64, 0, 0, 255, 192, 0, 0])
    }

    /// The accept predicate: only loopback and the device's own addresses get an answer.
    func testOnlyTheDevicesOwnAddressesAreAccepted() {
        let own = [loopback, Address(interface: "en0", bytes: [192, 168, 1, 40])]
        func accepted(_ host: String) -> Bool {
            LocalHTTPServer.isFromThisDevice(.hostPort(host: NWEndpoint.Host(host), port: 443), ownAddresses: own)
        }
        XCTAssertTrue(accepted("127.0.0.1"))
        XCTAssertTrue(accepted("127.0.0.2"))
        XCTAssertTrue(accepted("::1"))
        XCTAssertTrue(accepted("192.168.1.40"))
        XCTAssertTrue(accepted("::ffff:192.168.1.40"))
        // Another machine on the same Wi-Fi.
        XCTAssertFalse(accepted("192.168.1.41"))
        XCTAssertFalse(accepted("::ffff:192.168.1.41"))
        XCTAssertFalse(accepted("8.8.8.8"))
        XCTAssertFalse(accepted("fe80::1"))
        XCTAssertFalse(LocalHTTPServer.isFromThisDevice(.service(name: "a", type: "_http._tcp", domain: "local.",
                                                                 interface: nil), ownAddresses: own))
    }

    func testThisMacsAddressesIncludeLoopbackAndItsInstallAddress() throws {
        let all = LocalNetwork.interfaceAddresses()
        XCTAssertTrue(all.contains { $0.bytes == [127, 0, 0, 1] && $0.isLoopback })
        let address = try macInstallAddress()
        XCTAssertTrue(all.contains { $0.bytes == address.bytes && $0.interface == address.interface })
        XCTAssertTrue(LocalNetwork.isOwnAddress(address.bytes, ownAddresses: all))
    }
}
