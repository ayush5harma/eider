import CZsign
import Foundation
import X509

/// One signing identity: a .p12 (certificate and private key), its password
/// and the provisioning profile made for it, checked against each other.
public struct SigningCertificate: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case development
        case adHoc
        case enterprise
        case appStore
    }

    /// The certificate's subject common name, e.g. "Apple Development: Name (ID)".
    public let commonName: String
    public let teamIdentifier: String
    public let teamName: String
    public let profileName: String
    public let profileUUID: String
    /// The profile's application-identifier, e.g. "TEAM.*" or "TEAM.com.example.app".
    public let applicationIdentifierPattern: String
    public let kind: Kind
    public let certificateExpires: Date
    public let profileExpires: Date
    public let provisionedDevices: [String]
    public let provisionsAllDevices: Bool
    public let entitlements: [String: PlistValue]
    /// The files as given, for the caller to store; the password is not exposed
    /// because it belongs in the Keychain, not next to them.
    public let p12Data: Data
    public let profileData: Data

    let password: String
    let leafCertificateDER: Data
    /// The leaf's issuer (from the p12 or zsign's Apple WWDR set), for OCSP.
    let issuerCertificateDER: Data?

    /// The earlier of the certificate's and the profile's expiry.
    public var expires: Date { min(certificateExpires, profileExpires) }

    /// True when the profile's application-identifier ends in "*".
    public var isWildcard: Bool { applicationIdentifierPattern.hasSuffix("*") }

    public init(p12: Data, password: String, provisioningProfile: Data) throws {
        try self.init(p12: p12, password: password, provisioningProfile: provisioningProfile, now: Date())
    }

    init(p12: Data, password: String, provisioningProfile: Data, now: Date) throws {
        let identity = try P12Identity(p12: p12, password: password)
        let profile = try ProvisioningProfile(data: provisioningProfile)
        guard profile.developerCertificates.contains(identity.leafDER) else {
            throw SigningError.certificateNotInProfile(profileName: profile.name)
        }
        let certificate: Certificate
        do {
            certificate = try Certificate(derEncoded: Array(identity.leafDER))
        } catch {
            throw SigningError.unreadableCertificate
        }
        guard certificate.notValidAfter > now else {
            throw SigningError.certificateExpired(certificate.notValidAfter)
        }
        guard profile.expirationDate > now else {
            throw SigningError.profileExpired(profile.expirationDate)
        }

        commonName = Self.attribute(of: certificate.subject) { $0.type == .RDNAttributeType.commonName } ?? ""
        teamIdentifier = profile.teamIdentifier
            ?? Self.attribute(of: certificate.subject) { $0.type == .RDNAttributeType.organizationalUnitName } ?? ""
        teamName = profile.teamName
            ?? Self.attribute(of: certificate.subject) { $0.type == .RDNAttributeType.organizationName } ?? ""
        profileName = profile.name
        profileUUID = profile.uuid
        applicationIdentifierPattern = profile.applicationIdentifier
        kind = profile.kind
        certificateExpires = certificate.notValidAfter
        profileExpires = profile.expirationDate
        provisionedDevices = profile.provisionedDevices
        provisionsAllDevices = profile.provisionsAllDevices
        entitlements = profile.entitlements
        p12Data = p12
        profileData = provisioningProfile
        self.password = password
        leafCertificateDER = identity.leafDER
        issuerCertificateDER = identity.issuerDER
    }

    /// Whether an app signed with this profile can run on the device with this UDID.
    public func provisions(deviceUDID: String) -> Bool {
        provisionsAllDevices
            || provisionedDevices.contains { $0.caseInsensitiveCompare(deviceUDID) == .orderedSame }
    }

    /// Whether the profile covers this bundle identifier: any for "TEAM.*",
    /// a prefix for "TEAM.com.example.*", otherwise only the exact one.
    public func allows(bundleIdentifier: String) -> Bool {
        let pattern = applicationIdentifierPattern
        guard let dot = pattern.firstIndex(of: ".") else { return false }
        let appID = pattern[pattern.index(after: dot)...]
        if appID == "*" { return true }
        if appID.hasSuffix(".*") {
            return bundleIdentifier.hasPrefix(String(appID.dropLast()))
        }
        return appID == bundleIdentifier
    }

    /// The bundle identifier pattern without the team prefix, for messages.
    var allowedBundleIdentifiers: String {
        guard let dot = applicationIdentifierPattern.firstIndex(of: ".") else {
            return applicationIdentifierPattern
        }
        return String(applicationIdentifierPattern[applicationIdentifierPattern.index(after: dot)...])
    }

    private static func attribute(
        of name: DistinguishedName,
        where matches: (RelativeDistinguishedName.Attribute) -> Bool
    ) -> String? {
        for rdn in name {
            for attribute in rdn where matches(attribute) {
                return String(describing: attribute.value)
            }
        }
        return nil
    }
}

// The password, key and file bytes stay out of print(), dump() and logs.
extension SigningCertificate: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "SigningCertificate(\(commonName), team \(teamIdentifier), profile \"\(profileName)\", \(kind.rawValue), expires \(expires))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "commonName": commonName,
            "teamIdentifier": teamIdentifier,
            "profileName": profileName,
            "profileUUID": profileUUID,
            "kind": kind,
            "expires": expires,
        ])
    }
}

/// The p12 opened with OpenSSL, the parser zsign signs with.
struct P12Identity {
    let leafDER: Data
    let issuerDER: Data?

    init(p12: Data, password: String) throws {
        var leaf = eider_bytes(bytes: nil, length: 0)
        var issuer = eider_bytes(bytes: nil, length: 0)
        defer {
            eider_bytes_free(&leaf)
            eider_bytes_free(&issuer)
        }
        let status = p12.withUnsafeBytes { raw in
            eider_p12_read(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, password, &leaf, &issuer)
        }
        switch status {
        case EIDER_P12_OK:
            break
        case EIDER_P12_WRONG_PASSWORD:
            throw SigningError.wrongPassword
        case EIDER_P12_NO_IDENTITY:
            throw SigningError.noIdentityInCertificate
        default:
            throw SigningError.unreadableCertificate
        }
        leafDER = Data(bytes: leaf.bytes, count: leaf.length)
        issuerDER = issuer.length > 0 ? Data(bytes: issuer.bytes, count: issuer.length) : nil
    }
}
