import Foundation
import Security

enum CertificateKind: String, Codable, Sendable {
    case development, adHoc, enterprise, appStore

    var label: String {
        switch self {
        case .development: "Development"
        case .adHoc: "Ad Hoc"
        case .enterprise: "Enterprise"
        case .appStore: "App Store"
        }
    }
}

/// What a .mobileprovision says, read in the app so the Add sheet can show
/// the team, type and expiry as soon as the file is picked, before a password
/// is typed. The file is a CMS envelope around a plain XML property list, so
/// the plist is taken from between `<?xml` and `</plist>`; EiderSign checks
/// the signature and the pair as a whole when the certificate is added.
struct ProvisioningProfile: Codable, Hashable, Sendable {
    let name: String
    let uuid: String
    let teamID: String
    let teamName: String
    let appIDName: String?
    /// The application-identifier without its team prefix: "*" or "com.example.*" for a wildcard.
    let appIDPattern: String
    let created: Date?
    let expires: Date
    let kind: CertificateKind
    let provisionedDevices: [String]
    let provisionsAllDevices: Bool
    /// Common names of the certificates the profile allows, in its order.
    let certificateNames: [String]
    let entitlementKeys: [String]

    var isWildcard: Bool { appIDPattern.hasSuffix("*") }

    static func parse(_ data: Data) throws -> ProvisioningProfile {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { throw CertificateError.unreadableProfile }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let name = plist["Name"] as? String,
              let uuid = plist["UUID"] as? String,
              let expires = plist["ExpirationDate"] as? Date
        else { throw CertificateError.unreadableProfile }

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let teamID = (plist["TeamIdentifier"] as? [String])?.first ?? entitlements["com.apple.developer.team-identifier"] as? String ?? ""
        let applicationID = entitlements["application-identifier"] as? String ?? ""
        let pattern = applicationID.hasPrefix(teamID + ".") ? String(applicationID.dropFirst(teamID.count + 1)) : applicationID
        let devices = plist["ProvisionedDevices"] as? [String] ?? []
        let allDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        let getTaskAllow = entitlements["get-task-allow"] as? Bool ?? false
        let certificates = plist["DeveloperCertificates"] as? [Data] ?? []

        let kind: CertificateKind
        if allDevices {
            kind = .enterprise
        } else if !devices.isEmpty {
            kind = getTaskAllow ? .development : .adHoc
        } else {
            kind = .appStore
        }

        return ProvisioningProfile(
            name: name, uuid: uuid, teamID: teamID,
            teamName: plist["TeamName"] as? String ?? teamID,
            appIDName: plist["AppIDName"] as? String,
            appIDPattern: pattern,
            created: plist["CreationDate"] as? Date,
            expires: expires, kind: kind,
            provisionedDevices: devices, provisionsAllDevices: allDevices,
            certificateNames: certificates.compactMap(Self.commonName),
            entitlementKeys: entitlements.keys.sorted())
    }

    static func commonName(ofCertificate der: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }
}

enum CertificateError: LocalizedError {
    case unreadableProfile
    case missingFiles
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unreadableProfile:
            "That file is not a provisioning profile Eider can read. Choose the .mobileprovision that came with the certificate."
        case .missingFiles:
            "This certificate's files are missing. Remove it and add it again."
        case .keychain(let status):
            "The Keychain refused the password (\(status))."
        }
    }
}
