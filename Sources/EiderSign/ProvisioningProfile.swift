import Foundation

/// The plist inside a .mobileprovision. The CMS signature around it is not
/// verified: the profile only matters to iOS, which verifies it at install.
struct ProvisioningProfile {
    let name: String
    let uuid: String
    let teamIdentifier: String?
    let teamName: String?
    let applicationIdentifier: String
    let expirationDate: Date
    let provisionedDevices: [String]
    let provisionsAllDevices: Bool
    let entitlements: [String: PlistValue]
    let developerCertificates: [Data]

    init(data: Data) throws {
        guard let plist = Self.plist(in: data),
              let name = plist["Name"] as? String,
              let uuid = plist["UUID"] as? String,
              let expirationDate = plist["ExpirationDate"] as? Date,
              let entitlementsPlist = plist["Entitlements"] as? [String: Any],
              let applicationIdentifier = entitlementsPlist["application-identifier"] as? String
        else {
            throw SigningError.unreadableProfile
        }
        self.name = name
        self.uuid = uuid
        teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first
        teamName = plist["TeamName"] as? String
        self.applicationIdentifier = applicationIdentifier
        self.expirationDate = expirationDate
        provisionedDevices = plist["ProvisionedDevices"] as? [String] ?? []
        provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        entitlements = entitlementsPlist.compactMapValues(PlistValue.init(propertyList:))
        developerCertificates = plist["DeveloperCertificates"] as? [Data] ?? []
    }

    /// Development: get-task-allow and a device list. Ad hoc: a device list
    /// without get-task-allow. Enterprise: all devices. App Store: neither.
    var kind: SigningCertificate.Kind {
        if provisionsAllDevices { return .enterprise }
        if provisionedDevices.isEmpty { return .appStore }
        return entitlements["get-task-allow"]?.boolValue == true ? .development : .adHoc
    }

    /// The XML plist sits in the clear inside the CMS: from "<?xml" to "</plist>".
    private static func plist(in data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        return try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
    }
}
