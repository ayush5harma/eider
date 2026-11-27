import XCTest
@testable import EiderSign

final class SigningCertificateTests: XCTestCase {
    func testReadsTheCertificateAndTheProfile() throws {
        let material = try TestMaterial()
        let identity = try material.makeIdentity()

        let certificate = try SigningCertificate(
            p12: identity.p12, password: TestMaterial.password, provisioningProfile: identity.profile)

        XCTAssertEqual(certificate.commonName, "Apple Development: Eider Test (EIDRTEST01)")
        XCTAssertEqual(certificate.teamIdentifier, TestMaterial.team)
        XCTAssertEqual(certificate.teamName, "Eider Test Team")
        XCTAssertEqual(certificate.profileName, "Eider Test Wildcard")
        XCTAssertEqual(certificate.applicationIdentifierPattern, "EIDRTEST01.*")
        XCTAssertEqual(certificate.kind, .development)
        XCTAssertEqual(certificate.provisionedDevices, [TestMaterial.device])
        XCTAssertTrue(certificate.provisions(deviceUDID: TestMaterial.device.lowercased()))
        XCTAssertFalse(certificate.provisions(deviceUDID: "00008150-FFFFFFFFFFFFFFFF"))
        XCTAssertEqual(certificate.entitlements["get-task-allow"], .bool(true))
        XCTAssertEqual(certificate.entitlements["application-identifier"], .string("EIDRTEST01.*"))
        XCTAssertNotNil(certificate.issuerCertificateDER, "the CA in the p12 is the issuer")
        XCTAssertEqual(certificate.expires, min(certificate.certificateExpires, certificate.profileExpires))
        XCTAssertGreaterThan(certificate.certificateExpires, Date().addingTimeInterval(29 * 86_400))
        // The profile in TestMaterial expires in 20 days, before the certificate.
        XCTAssertEqual(certificate.expires, certificate.profileExpires)
        XCTAssertTrue(certificate.isWildcard)
        XCTAssertTrue(certificate.allows(bundleIdentifier: "com.example.anything"))
    }

    func testTheDescriptionKeepsThePasswordOut() throws {
        let material = try TestMaterial()
        let identity = try material.makeIdentity()
        let certificate = try SigningCertificate(
            p12: identity.p12, password: TestMaterial.password, provisioningProfile: identity.profile)
        var dumped = ""
        dump(certificate, to: &dumped)
        for text in [String(describing: certificate), String(reflecting: certificate), dumped] {
            XCTAssertFalse(text.contains(TestMaterial.password), text)
        }
    }

    func testProfileKinds() throws {
        let material = try TestMaterial()
        let leaf = try material.makeLeaf("leaf")
        let p12 = try material.makeP12("leaf")
        func kind(_ profile: Data) throws -> SigningCertificate.Kind {
            try SigningCertificate(p12: p12, password: TestMaterial.password, provisioningProfile: profile).kind
        }
        XCTAssertEqual(try kind(material.makeProfile(certificates: [leaf], getTaskAllow: false)), .adHoc)
        XCTAssertEqual(try kind(material.makeProfile(certificates: [leaf], getTaskAllow: nil)), .adHoc)
        XCTAssertEqual(try kind(material.makeProfile(certificates: [leaf], allDevices: true, getTaskAllow: false)), .enterprise)
        XCTAssertEqual(try kind(material.makeProfile(certificates: [leaf], devices: [], getTaskAllow: false)), .appStore)

        let enterprise = try SigningCertificate(
            p12: p12, password: TestMaterial.password,
            provisioningProfile: material.makeProfile(certificates: [leaf], allDevices: true, getTaskAllow: false))
        XCTAssertTrue(enterprise.provisions(deviceUDID: "any-device"))
    }

    func testExplicitAndPrefixAppIDs() throws {
        let material = try TestMaterial()
        let leaf = try material.makeLeaf("leaf")
        let p12 = try material.makeP12("leaf")
        let explicit = try SigningCertificate(
            p12: p12, password: TestMaterial.password,
            provisioningProfile: material.makeProfile(certificates: [leaf], appID: "EIDRTEST01.com.example.app"))
        XCTAssertFalse(explicit.isWildcard)
        XCTAssertTrue(explicit.allows(bundleIdentifier: "com.example.app"))
        XCTAssertFalse(explicit.allows(bundleIdentifier: "com.example.app.widget"))

        let prefix = try SigningCertificate(
            p12: p12, password: TestMaterial.password,
            provisioningProfile: material.makeProfile(certificates: [leaf], appID: "EIDRTEST01.com.example.*"))
        XCTAssertTrue(prefix.allows(bundleIdentifier: "com.example.app"))
        XCTAssertFalse(prefix.allows(bundleIdentifier: "org.other.app"))
    }

    func testRefusesAWrongPassword() throws {
        let material = try TestMaterial()
        let identity = try material.makeIdentity()
        XCTAssertThrowsError(
            try SigningCertificate(p12: identity.p12, password: "wrong", provisioningProfile: identity.profile)
        ) { error in
            XCTAssertEqual(error as? SigningError, .wrongPassword)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "The password for the certificate is wrong.")
        }
    }

    func testRefusesAProfileMadeForAnotherCertificate() throws {
        let material = try TestMaterial()
        try material.makeLeaf("mine")
        let p12 = try material.makeP12("mine")
        let other = try material.makeLeaf("other")
        let profile = try material.makeProfile(certificates: [other], name: "Someone Else's")
        XCTAssertThrowsError(
            try SigningCertificate(p12: p12, password: TestMaterial.password, provisioningProfile: profile)
        ) { error in
            XCTAssertEqual(error as? SigningError, .certificateNotInProfile(profileName: "Someone Else's"))
        }
    }

    func testRefusesExpiredCertificateAndProfile() throws {
        let material = try TestMaterial()
        let leaf = try material.makeLeaf("leaf")
        let p12 = try material.makeP12("leaf")

        let expiredProfile = try material.makeProfile(certificates: [leaf], expires: Date().addingTimeInterval(-60))
        XCTAssertThrowsError(
            try SigningCertificate(p12: p12, password: TestMaterial.password, provisioningProfile: expiredProfile)
        ) { error in
            guard case .profileExpired = error as? SigningError else { return XCTFail("\(error)") }
        }

        // The leaf is valid for 30 days; seen from day 40 it has expired.
        let profile = try material.makeProfile(certificates: [leaf], expires: Date().addingTimeInterval(90 * 86_400))
        XCTAssertThrowsError(
            try SigningCertificate(
                p12: p12, password: TestMaterial.password, provisioningProfile: profile,
                now: Date().addingTimeInterval(40 * 86_400))
        ) { error in
            guard case .certificateExpired = error as? SigningError else { return XCTFail("\(error)") }
        }
    }

    func testRefusesFilesThatAreNotAP12OrAProfile() throws {
        let material = try TestMaterial()
        let identity = try material.makeIdentity()
        XCTAssertThrowsError(
            try SigningCertificate(p12: Data("not a p12".utf8), password: "", provisioningProfile: identity.profile)
        ) { XCTAssertEqual($0 as? SigningError, .unreadableCertificate) }
        XCTAssertThrowsError(
            try SigningCertificate(p12: identity.p12, password: TestMaterial.password, provisioningProfile: Data("nope".utf8))
        ) { XCTAssertEqual($0 as? SigningError, .unreadableProfile) }
    }
}
