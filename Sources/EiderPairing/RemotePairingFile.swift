import CryptoKit
import Foundation

/// A RemotePairing ("RP") pairing file: the host's Ed25519 key pair and the host identifier
/// the iPhone recorded when it paired with that host.
///
/// The accepted format is idevice's (`remote_pairing/rp_pairing_file.rs`): a property list
/// with `public_key` and `private_key` (32 raw bytes each), `identifier` (string) and an
/// optional `alt_irk`. This is what idevice, StikDebug and Feather's pairing mode use on
/// iOS 17.4 and later. Feather #733/#739 and StikDebug #446/#471 trace their pairing errors
/// to a lockdown pairing file given where an RP one is needed, so that case is named.
///
/// pymobiledevice3's `remote_<udid>.plist` has the same keys but no `identifier`: it derives
/// the identifier from the pairing computer's hostname (uppercase UUIDv3 in the DNS
/// namespace, `pair_records.generate_host_id`). An iPhone cannot know that hostname, so such
/// a file is refused here with the way out: convert it on the computer that made it with
/// `Scripts/rppairing-from-pymobiledevice3.sh`.
public struct RemotePairingFile: Sendable {
    /// The identifier the iPhone knows this pairing by.
    public let hostIdentifier: String
    /// The file's bytes, as handed to the installer.
    public let data: Data

    private static let keyLength = 32

    public init(data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            throw PairingInstallError.invalidPairingFile(
                "The file is not a pairing file (not a property list).")
        }
        if Self.isLockdownPairRecord(dictionary) {
            throw PairingInstallError.invalidPairingFile(
                "This is a lockdown pairing file (from idevicepair, Jitterbug or a Mac's "
                + "lockdown records). Pairing mode needs a RemotePairing pairing file, which "
                + "has public_key, private_key and identifier.")
        }
        guard let privateKey = dictionary["private_key"] as? Data,
              let publicKey = dictionary["public_key"] as? Data else {
            throw PairingInstallError.invalidPairingFile(
                "The file has no RemotePairing keys (public_key and private_key).")
        }
        guard let identifier = dictionary["identifier"] as? String else {
            if dictionary["remote_unlock_host_key"] != nil || dictionary["peer_alt_irk"] != nil {
                throw PairingInstallError.invalidPairingFile(
                    "This is a pymobiledevice3 remote pairing record, which leaves out the host "
                    + "identifier. Convert it on the computer that made it with "
                    + "Scripts/rppairing-from-pymobiledevice3.sh, then import the result.")
            }
            throw PairingInstallError.invalidPairingFile("The pairing file has no identifier.")
        }
        guard !identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PairingInstallError.invalidPairingFile("The pairing file's identifier is empty.")
        }
        guard privateKey.count == Self.keyLength, publicKey.count == Self.keyLength else {
            throw PairingInstallError.invalidPairingFile(
                "The pairing file's keys are not 32-byte Ed25519 keys.")
        }
        guard let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
              signing.publicKey.rawRepresentation == publicKey else {
            throw PairingInstallError.invalidPairingFile(
                "The pairing file's public key does not belong to its private key.")
        }
        if let altIRK = dictionary["alt_irk"], !(altIRK is Data) {
            throw PairingInstallError.invalidPairingFile("The pairing file's alt_irk is not data.")
        }
        hostIdentifier = identifier
        self.data = data
    }

    /// Lockdown pair records (usbmuxd, idevicepair, Jitterbug) carry certificates and a
    /// HostID; an RP pairing file has none of these.
    private static func isLockdownPairRecord(_ dictionary: [String: Any]) -> Bool {
        let lockdownKeys = ["HostID", "HostCertificate", "DeviceCertificate", "HostPrivateKey",
                            "RootCertificate", "SystemBUID"]
        return lockdownKeys.contains { dictionary[$0] != nil }
    }
}
