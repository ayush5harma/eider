import CryptoKit
import Foundation
import XCTest
@testable import EiderPairing

/// Pairing files made here from fresh keys; no real pairing material is ever used.
final class RemotePairingFileTests: XCTestCase {
    private func plist(_ dictionary: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
    }

    private func keys() -> (privateKey: Data, publicKey: Data) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation, key.publicKey.rawRepresentation)
    }

    private func assertRejected(_ data: Data, mentioning text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RemotePairingFile(data: data), file: file, line: line) { error in
            guard case PairingInstallError.invalidPairingFile(let message) = error else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(text), "\(message) does not mention \(text)", file: file, line: line)
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
        }
    }

    func testAcceptsIdeviceFormatXML() throws {
        let (privateKey, publicKey) = keys()
        let identifier = "3C9A1E1B-6D5B-3D0F-9E2A-0F4A8C2B7D11"
        let data = try plist(["private_key": privateKey, "public_key": publicKey, "identifier": identifier])
        let file = try RemotePairingFile(data: data)
        XCTAssertEqual(file.hostIdentifier, identifier)
        XCTAssertEqual(file.data, data)
    }

    func testAcceptsBinaryPlistWithAltIRK() throws {
        let (privateKey, publicKey) = keys()
        let data = try plist(["private_key": privateKey, "public_key": publicKey,
                              "identifier": "host", "alt_irk": Data(repeating: 7, count: 16)],
                             format: .binary)
        XCTAssertEqual(try RemotePairingFile(data: data).hostIdentifier, "host")
    }

    func testRejectsPymobiledevice3RecordWithConversionHint() throws {
        let (privateKey, publicKey) = keys()
        let data = try plist(["private_key": privateKey, "public_key": publicKey,
                              "remote_unlock_host_key": "", "peer_alt_irk": Data(repeating: 1, count: 16)])
        assertRejected(data, mentioning: "Scripts/rppairing-from-pymobiledevice3.sh")
    }

    func testRejectsLockdownPairRecord() throws {
        let data = try plist(["HostID": "ABC", "SystemBUID": "DEF",
                              "HostCertificate": Data([1]), "DeviceCertificate": Data([2])])
        assertRejected(data, mentioning: "lockdown pairing file")
    }

    func testRejectsMissingIdentifier() throws {
        let (privateKey, publicKey) = keys()
        assertRejected(try plist(["private_key": privateKey, "public_key": publicKey]),
                       mentioning: "no identifier")
    }

    func testRejectsEmptyIdentifier() throws {
        let (privateKey, publicKey) = keys()
        assertRejected(try plist(["private_key": privateKey, "public_key": publicKey, "identifier": " "]),
                       mentioning: "identifier is empty")
    }

    func testRejectsShortKeys() throws {
        assertRejected(try plist(["private_key": Data(count: 31), "public_key": Data(count: 32), "identifier": "h"]),
                       mentioning: "32-byte")
    }

    func testRejectsMismatchedKeys() throws {
        let first = keys(), second = keys()
        assertRejected(try plist(["private_key": first.privateKey, "public_key": second.publicKey, "identifier": "h"]),
                       mentioning: "does not belong")
    }

    func testRejectsKeysOfWrongType() throws {
        assertRejected(try plist(["private_key": "text", "public_key": "text", "identifier": "h"]),
                       mentioning: "no RemotePairing keys")
    }

    func testRejectsAltIRKOfWrongType() throws {
        let (privateKey, publicKey) = keys()
        assertRejected(try plist(["private_key": privateKey, "public_key": publicKey,
                                  "identifier": "h", "alt_irk": "text"]),
                       mentioning: "alt_irk")
    }

    func testRejectsGarbageAndNonDictionary() throws {
        assertRejected(Data("not a plist".utf8), mentioning: "not a property list")
        assertRejected(Data(), mentioning: "not a property list")
        assertRejected(try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0),
                       mentioning: "not a property list")
    }
}
