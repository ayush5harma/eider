import Foundation

/// The installer the app uses. A placeholder until EiderInstall lands (IPA
/// unpack and repack, the loopback HTTPS server, the itms-services hand-off;
/// docs/IOS.md): replace this file's body with calls into it. Nothing else
/// changes.
struct AppInstaller: DeviceInstaller {
    func unpack(ipaAt ipaURL: URL, into directory: URL) async throws -> URL {
        throw FeatureUnavailable(feature: "Unpacking an IPA")
    }

    func package(appAt appURL: URL, into ipaURL: URL) async throws {
        throw FeatureUnavailable(feature: "Packaging an IPA")
    }

    func install(ipaAt ipaURL: URL, bundleIdentifier: String, version: String, title: String) async throws {
        throw FeatureUnavailable(feature: "Installing on this device")
    }
}
