import Foundation

/// Everything EiderSign refuses or fails at, worded for the person using the app.
public enum SigningError: Error, Equatable, Sendable, LocalizedError {
    case unreadableCertificate
    case wrongPassword
    case noIdentityInCertificate
    case unreadableProfile
    case certificateNotInProfile(profileName: String)
    case certificateExpired(Date)
    case profileExpired(Date)
    case notAnApp(path: String)
    case bundleIdentifierNotAllowed(bundleIdentifier: String, profileName: String, allowed: String)
    case invalidBundleIdentifier(String)
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableCertificate:
            return "The certificate file is not a .p12 file that can be read."
        case .wrongPassword:
            return "The password for the certificate is wrong."
        case .noIdentityInCertificate:
            return "The .p12 file has no private key paired with a certificate. Export the certificate together with its private key."
        case .unreadableProfile:
            return "The provisioning profile is not a .mobileprovision file that can be read."
        case .certificateNotInProfile(let profileName):
            return "The provisioning profile \"\(profileName)\" was not made for this certificate. Choose the profile that includes it."
        case .certificateExpired(let date):
            return "The certificate expired on \(Self.format(date))."
        case .profileExpired(let date):
            return "The provisioning profile expired on \(Self.format(date))."
        case .notAnApp(let path):
            return "\(path) is not an app: it has no Info.plist naming a bundle identifier and an executable."
        case .bundleIdentifierNotAllowed(let bundleIdentifier, let profileName, let allowed):
            return "The provisioning profile \"\(profileName)\" only signs \(allowed), not \(bundleIdentifier). Change the bundle identifier or use a wildcard profile."
        case .invalidBundleIdentifier(let identifier):
            return "\"\(identifier)\" is not a bundle identifier: use letters, digits, hyphens and dots, such as com.example.app."
        case .signingFailed(let reason):
            return "Signing failed: \(reason)"
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
