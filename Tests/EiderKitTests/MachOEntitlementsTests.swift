import Foundation
import XCTest
@testable import EiderKit

/// A code-signature SuperBlob built by hand, so malformed ones can be made on purpose.
private enum Blob {
    static func be32(_ value: Int) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    static func plist(_ groups: [String]) -> Data {
        let dict: [String: Any] = [AppGroups.entitlementKey: groups, "com.apple.security.app-sandbox": true]
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    static func entitlements(_ plist: Data, magic: Int = 0xFADE_7171, length: Int? = nil) -> Data {
        be32(magic) + be32(length ?? plist.count + 8) + plist
    }

    /// Index entries point at consecutive blobs; `offsetFor` and `magic`/`length` overrides break them.
    static func superBlob(slot: Int = 5, magic: Int = 0xFADE_0CC0, blob: Data, offset: Int? = nil, length: Int? = nil, count: Int = 1) -> Data {
        let indexEnd = 12 + 8 * count
        let body = be32(slot) + be32(offset ?? indexEnd)
        var index = body
        for _ in 1..<max(count, 1) { index += be32(0) + be32(indexEnd) }
        let total = indexEnd + blob.count
        return be32(magic) + be32(length ?? total) + be32(count) + index + blob
    }
}

final class MachOEntitlementsBlobTests: XCTestCase {
    func testReadsTheEntitlementsBlob() throws {
        let signature = Blob.superBlob(blob: Blob.entitlements(Blob.plist(["group.a.b"])))
        let entitlements = try XCTUnwrap(MachOEntitlements.entitlements(inSignature: signature))
        XCTAssertEqual(entitlements[AppGroups.entitlementKey] as? [String], ["group.a.b"])
    }

    func testNilForEveryMalformedSignature() {
        let good = Blob.entitlements(Blob.plist(["group.a.b"]))
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("shorter than a header", Data([0xFA, 0xDE, 0x0C])),
            ("wrong super blob magic", Blob.superBlob(magic: 0xFADE_0CC1, blob: good)),
            ("no entitlements slot", Blob.superBlob(slot: 0, blob: good)),
            ("index points past the end", Blob.superBlob(blob: good, offset: 100_000)),
            ("index points into the index", Blob.superBlob(blob: good, offset: 4)),
            ("index offset near Int max", Blob.superBlob(blob: good, offset: 0xFFFF_FFFF)),
            ("super blob length past the data", Blob.superBlob(blob: good, length: 100_000)),
            ("count larger than the data", Blob.superBlob(blob: good, count: 5000)),
            ("wrong entitlements magic", Blob.superBlob(blob: Blob.entitlements(Blob.plist(["g"]), magic: 0xFADE_7172))),
            ("entitlements length past the end", Blob.superBlob(blob: Blob.entitlements(Blob.plist(["g"]), length: 100_000))),
            ("entitlements length below its header", Blob.superBlob(blob: Blob.entitlements(Blob.plist(["g"]), length: 4))),
            ("entitlements blob cut off", Blob.superBlob(blob: good).dropLast(20)),
            ("not a plist", Blob.superBlob(blob: Blob.entitlements(Data("not a plist".utf8)))),
            ("a plist that is not a dictionary", Blob.superBlob(blob: Blob.entitlements(
                try! PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0)))),
        ]
        for (name, data) in cases {
            XCTAssertNil(MachOEntitlements.entitlements(inSignature: Data(data)), name)
        }
    }
}

final class MachOEntitlementsFileTests: XCTestCase {
    private let group = "group.local.eider.test"

    private func entitlementsFile(_ fixtures: MachOFixtures, groups: [String]) throws -> URL {
        let url = fixtures.url("ents.plist")
        try Blob.plist(groups).write(to: url)
        return url
    }

    private func signedBinary(_ fixtures: MachOFixtures, name: String = "Signed", arguments: [String] = [], groups: [String]) throws -> URL {
        let binary = try fixtures.compile(name, source: "int main(void) { return 0; }\n", arguments)
        let ents = try entitlementsFile(fixtures, groups: groups)
        guard FileManager.default.fileExists(atPath: "/usr/bin/codesign") else { throw XCTSkip("codesign is not available") }
        let result = try ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", ents.path, binary.path])
        guard result.succeeded else { throw XCTSkip("codesign failed: \(result.errorLine)") }
        return binary
    }

    func testReadsTheGroupsOfARealAdHocSignedBinary() throws {
        let fixtures = try MachOFixtures()
        let binary = try signedBinary(fixtures, groups: [group, "group.second"])
        let entitlements = try XCTUnwrap(MachOEntitlements.read(at: binary))
        XCTAssertEqual(entitlements[AppGroups.entitlementKey] as? [String], [group, "group.second"])
        XCTAssertEqual(AppGroups.read(from: binary), AppGroups.Result(groups: [group, "group.second"], dropped: 0))
    }

    func testReadsTheArm64SliceOfAFatFile() throws {
        let fixtures = try MachOFixtures()
        let binary = try signedBinary(fixtures, name: "Fat", arguments: ["-arch", "arm64", "-arch", "x86_64"], groups: [group])
        XCTAssertEqual(MachOFiles.kind(of: binary), .fat)
        XCTAssertEqual(MachOEntitlements.read(at: binary)?[AppGroups.entitlementKey] as? [String], [group])
    }

    func testUnsignedBinaryAndNonMachOFileGiveNil() throws {
        let fixtures = try MachOFixtures()
        let unsigned = try fixtures.compile("Unsigned", source: "int main(void) { return 0; }\n", ["-Wl,-no_adhoc_codesign"])
        XCTAssertNil(MachOEntitlements.read(at: unsigned))
        let text = fixtures.url("text.txt")
        try Data("hello".utf8).write(to: text)
        XCTAssertNil(MachOEntitlements.read(at: text))
        XCTAssertNil(MachOEntitlements.read(at: fixtures.url("missing")))
    }

    func testSignedWithoutEntitlementsGivesNoGroups() throws {
        let fixtures = try MachOFixtures()
        let binary = try fixtures.compile("Plain", source: "int main(void) { return 0; }\n", [])
        try fixtures.sign(binary)
        XCTAssertNil(MachOEntitlements.read(at: binary)?[AppGroups.entitlementKey])
        XCTAssertEqual(AppGroups.read(from: binary), AppGroups.Result(groups: [], dropped: 0))
    }

    func testATruncatedFileGivesNilNotACrash() throws {
        let fixtures = try MachOFixtures()
        let binary = try signedBinary(fixtures, groups: [group])
        let whole = try Data(contentsOf: binary)
        for keep in [3, 20, 200, whole.count / 2, whole.count - 300, whole.count - 1] {
            let cut = fixtures.url("cut\(keep)")
            try whole.prefix(keep).write(to: cut)
            XCTAssertNil(MachOEntitlements.read(at: cut), "truncated to \(keep) of \(whole.count) bytes")
        }
    }

    func testACorruptCodeSignatureCommandGivesNil() throws {
        let fixtures = try MachOFixtures()
        let binary = try signedBinary(fixtures, groups: [group])
        let original = try Data(contentsOf: binary)
        let command = try XCTUnwrap(MachOImage(bytes: original).loadCommands().first { $0.cmd == MachOEntitlements.lcCodeSignature })
        let oversize: [(String, Int, UInt32)] = [
            ("dataoff past the end", command.offset + 8, UInt32(original.count)),
            ("dataoff near UInt32 max", command.offset + 8, 0xFFFF_FFF0),
            ("datasize past the end", command.offset + 12, UInt32(original.count)),
            ("datasize UInt32 max", command.offset + 12, 0xFFFF_FFFF),
            ("datasize zero", command.offset + 12, 0),
        ]
        for (name, at, value) in oversize {
            var bytes = original
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.replaceSubrange(at..<at + 4, with: $0) }
            let url = fixtures.url("corrupt")
            try bytes.write(to: url)
            XCTAssertNil(MachOEntitlements.read(at: url), name)
        }
    }
}

final class AppGroupsFilterTests: XCTestCase {
    private func filter(_ groups: Any) -> AppGroups.Result {
        AppGroups.filter([AppGroups.entitlementKey: groups])
    }

    func testKeepsPlainIDs() {
        let ids = ["group.app.ish.iSH", "ABCDE12345.group.x", "a", "9z", "group.with-dash_and.under"]
        XCTAssertEqual(filter(ids), AppGroups.Result(groups: ids, dropped: 0))
    }

    func testDropsIDsThatCouldReachAPathOrBreakAPlist() {
        let bad = ["../x", "a/b", "", ".hidden", "-lead", "_lead", "a..b", "a b", "a&b", "a<b", "g\u{0}x", "gr\u{00F6}up", String(repeating: "a", count: 256)]
        XCTAssertEqual(filter(bad + ["group.ok"]), AppGroups.Result(groups: ["group.ok"], dropped: bad.count))
    }

    func testAcceptsTheLongestAllowedID() {
        let longest = String(repeating: "a", count: 255)
        XCTAssertEqual(filter([longest]).groups, [longest])
    }

    func testDropsNonStringEntries() {
        XCTAssertEqual(filter(["group.ok", 5, true, ["x"], ["k": "v"]] as [Any]), AppGroups.Result(groups: ["group.ok"], dropped: 4))
    }

    func testAValueThatIsNotAnArrayIsDroppedAndNoValueMeansNone() {
        XCTAssertEqual(filter("group.x"), AppGroups.Result(groups: [], dropped: 1))
        XCTAssertEqual(AppGroups.filter([:]), AppGroups.Result(groups: [], dropped: 0))
        XCTAssertEqual(AppGroups.filter(nil), AppGroups.Result(groups: [], dropped: 0))
    }

    func testRepeatsAreMergedAndTheCountIsCapped() {
        XCTAssertEqual(filter(["g.a", "g.a"]), AppGroups.Result(groups: ["g.a"], dropped: 0))
        let many = (0..<40).map { "group.n\($0)" }
        let result = filter(many)
        XCTAssertEqual(result.groups, Array(many.prefix(32)))
        XCTAssertEqual(result.dropped, 8)
    }

    func testOnlyApplicationGroupsIsReadFromTheOriginalEntitlements() {
        let original: [String: Any] = [
            "application-identifier": "CK5SXRTBR7.app.ish.iSH", "com.apple.developer.team-identifier": "CK5SXRTBR7",
            "keychain-access-groups": ["CK5SXRTBR7.*"], AppGroups.entitlementKey: ["group.app.ish.iSH"],
        ]
        XCTAssertEqual(AppGroups.filter(original).groups, ["group.app.ish.iSH"])
    }
}

final class BundleSignerEntitlementsTests: XCTestCase {
    private func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    func testWithoutGroupsTheBaseSetIsUnchanged() throws {
        let entitlements = try parse(BundleSigner.entitlementsPlist(appGroups: []))
        XCTAssertEqual(entitlements.count, BundleSigner.baseEntitlements.count)
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.print"] as? Bool, true)
        XCTAssertNil(entitlements[AppGroups.entitlementKey])
    }

    func testGroupsAreAddedToTheBaseSet() throws {
        let entitlements = try parse(BundleSigner.entitlementsPlist(appGroups: ["group.app.ish.iSH", "group.b"]))
        XCTAssertEqual(entitlements.count, BundleSigner.baseEntitlements.count + 1)
        XCTAssertEqual(entitlements[AppGroups.entitlementKey] as? [String], ["group.app.ish.iSH", "group.b"])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
    }

    func testTheBaseSetCarriesNothingTiedToATeam() {
        for key in BundleSigner.baseEntitlements.keys {
            XCTAssertTrue(key.hasPrefix("com.apple.security."), key)
            XCTAssertNotEqual(key, "com.apple.security.application-groups")
        }
    }

    func testTheSignedAppCarriesTheGroup() throws {
        let fixtures = try MachOFixtures()
        let app = fixtures.url("Grp.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let executable = try fixtures.compile("Exec", source: "int main(void) { return 0; }\n", [])
        try FileManager.default.copyItem(at: executable, to: app.appendingPathComponent("Exec"))
        let info = ["CFBundleIdentifier": "test.groups", "CFBundleExecutable": "Exec", "CFBundleName": "Grp"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))

        let signer = BundleSigner(app: app, workDirectory: fixtures.directory, relative: { $0.lastPathComponent })
        try signer.sign(machOs: [app.appendingPathComponent("Exec")], appGroups: ["group.local.eider.test"])

        let read = MachOEntitlements.read(at: app.appendingPathComponent("Exec"))
        XCTAssertEqual(read?[AppGroups.entitlementKey] as? [String], ["group.local.eider.test"])
        XCTAssertEqual(read?["com.apple.security.app-sandbox"] as? Bool, true)
    }
}
