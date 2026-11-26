import Foundation
import XCTest
@testable import EiderKit

/// Which shims an install links, decided from the dylibs the bundle's binaries
/// link. The names come out of an untrusted IPA, so they may only be compared
/// to fixed framework names.
final class ShimLinkerDecisionTests: XCTestCase {
    private let system = "/System/Library/Frameworks"

    private func shims(keychain: Bool = true, _ linked: [String]) -> [Shim] {
        ShimLinker.shimsToLink(keychain: keychain, linkedDylibs: linked).map(\.shim)
    }

    func testPlainAppGetsKeychainAndGroupsOnly() {
        XCTAssertEqual(shims(["\(system)/UIKit.framework/UIKit", "/usr/lib/libSystem.B.dylib"]), [.keychain, .groups])
    }

    func testCallKitLinkGetsTheCallKitShimAndNotTheCameraShim() {
        let result = shims(["\(system)/CallKit.framework/CallKit"])
        XCTAssertTrue(result.contains(.callKit))
        XCTAssertFalse(result.contains(.camera))
    }

    func testAVFoundationLinkGetsTheCameraShimAndNotTheCallKitShim() {
        let result = shims(["\(system)/AVFoundation.framework/AVFoundation"])
        XCTAssertTrue(result.contains(.camera))
        XCTAssertFalse(result.contains(.callKit))
    }

    func testOpenGLESStillGetsItsShim() {
        XCTAssertEqual(shims(["\(system)/OpenGLES.framework/OpenGLES"]), [.keychain, .gles, .groups])
    }

    func testEveryFrameworkLinksInTheLegacyOrder() {
        let linked = ["AVFoundation", "CallKit", "OpenGLES"].map { "\(system)/\($0).framework/\($0)" }
        XCTAssertEqual(shims(linked), [.keychain, .gles, .callKit, .camera, .groups])
    }

    func testYouTubeGetsTheQuirksShimLast() {
        let result = ShimLinker.shimsToLink(keychain: true, linkedDylibs: [], bundleID: "com.google.ios.youtube").map(\.shim)
        XCTAssertEqual(result, [.keychain, .groups, .quirks])
    }

    func testOnlyAnExactBundleIDGetsTheQuirksShim() {
        for id in ["", "com.example.app", "com.google.ios.youtubemusic", "com.google.ios.youtube.extension", "COM.GOOGLE.IOS.YOUTUBE"] {
            let result = ShimLinker.shimsToLink(keychain: true, linkedDylibs: [], bundleID: id).map(\.shim)
            XCTAssertFalse(result.contains(.quirks), id)
        }
    }

    func testKeychainOptOutDropsOnlyTheKeychainShim() {
        XCTAssertEqual(shims(keychain: false, ["\(system)/CallKit.framework/CallKit"]), [.callKit, .groups])
    }

    func testAnyBinaryOfTheBundleCountsNotOnlyTheMainExecutable() {
        // The caller passes the union over every binary (frameworks, extensions), as the shell installer did.
        let fromAnEmbeddedFramework = ["\(system)/Foundation.framework/Foundation", "\(system)/AVFoundation.framework/AVFoundation"]
        XCTAssertTrue(shims(fromAnEmbeddedFramework).contains(.camera))
    }

    func testOnlyAWholeFrameworkPathComponentMatches() {
        // A look-alike name, a bare name and a path fragment must not link a shim.
        XCTAssertEqual(shims(["@rpath/MyCallKit.framework/MyCallKit", "CallKit", "/x/CallKit.dylib", "/x/AVFoundationExtras.framework/x"]),
                       [.keychain, .groups])
    }

    func testNamesAreNeverUsedAsPaths() {
        // A hostile name that looks like a traversal still only decides yes or no.
        let result = ShimLinker.shimsToLink(keychain: true, linkedDylibs: ["../../../etc/CallKit.framework/../../x"])
        XCTAssertEqual(result.map(\.shim), [.keychain, .callKit, .groups])
        XCTAssertEqual(Set(result.map(\.shim.rawValue)), ["libipakeychain.dylib", "libipacallkit.dylib", "libipagroups.dylib"])
    }

    func testNewShimNamesMatchTheShellInstallersAndInstallFromFrameworks() {
        XCTAssertEqual(Shim.callKit.rawValue, "libipacallkit.dylib")
        XCTAssertEqual(Shim.camera.rawValue, "libipacamera.dylib")
        XCTAssertEqual(Shim.callKit.installName, "@executable_path/Frameworks/libipacallkit.dylib")
        XCTAssertEqual(Shim.camera.installName, "@executable_path/Frameworks/libipacamera.dylib")
    }
}
