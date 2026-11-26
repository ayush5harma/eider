import Foundation
import XCTest
@testable import EiderKit

final class InterfaceScaleTests: XCTestCase {
    private var home: URL!
    private var containers: URL { home.appendingPathComponent("containers", isDirectory: true) }

    override func setUpWithError() throws {
        // Under /tmp: cfprefsd declines to write a domain under /var/folders
        // (the usual temporary directory), and AppPreferences then reports a failure.
        home = URL(fileURLWithPath: "/tmp/eider-tests-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Values

    func testArgumentsPeopleTypeAreRead() {
        XCTAssertEqual(InterfaceScale(argument: "auto"), .auto)
        XCTAssertEqual(InterfaceScale(argument: "AUTO"), .auto)
        XCTAssertEqual(InterfaceScale(argument: "77%"), .ipad)
        XCTAssertEqual(InterfaceScale(argument: "ipad"), .ipad)
        XCTAssertEqual(InterfaceScale(argument: "0.85"), .percent85)
        XCTAssertEqual(InterfaceScale(argument: "100"), .percent100)
        XCTAssertEqual(InterfaceScale(argument: "1.15"), .percent115)
        XCTAssertEqual(InterfaceScale(argument: "mac-idiom"), .macIdiom)
        XCTAssertNil(InterfaceScale(argument: "90"))
        XCTAssertNil(InterfaceScale(argument: ""))
    }

    func testAnEntryWrittenBeforeTheSettingHasNoneAndAnUnknownValueReadsAsAuto() throws {
        let options = InstallOptions(interfaceScale: .percent115)
        var json = try XCTUnwrap(String(data: JSONEncoder().encode(options), encoding: .utf8))
        XCTAssertTrue(json.contains(#""interfaceScale":"115""#), json)

        let old = json.replacingOccurrences(of: #","interfaceScale":"115""#, with: "").replacingOccurrences(of: #""interfaceScale":"115","#, with: "")
        XCTAssertNil(try JSONDecoder().decode(InstallOptions.self, from: Data(old.utf8)).interfaceScale)

        json = json.replacingOccurrences(of: #""interfaceScale":"115""#, with: #""interfaceScale":"140""#)
        XCTAssertEqual(try JSONDecoder().decode(InstallOptions.self, from: Data(json.utf8)).interfaceScale, .auto)
    }

    func testFixedValuesGiveTheirFactorAndIPadAndMacIdiomRemoveTheKey() {
        XCTAssertEqual(InterfaceScale.percent85.factor(on: nil), 0.85)
        XCTAssertEqual(InterfaceScale.percent100.factor(on: nil), 1.0)
        XCTAssertEqual(InterfaceScale.percent115.factor(on: nil), 1.15)
        XCTAssertNil(InterfaceScale.ipad.factor(on: nil))
        XCTAssertNil(InterfaceScale.macIdiom.factor(on: nil))
    }

    // MARK: Auto

    /// The owner's 14-inch MacBook Pro at "looks like 1800 x 1125" (measured 2026-11-27).
    private let builtIn = DisplayMetrics(pointWidth: 1800, pointHeight: 1125, backingScale: 2, physicalWidthMM: 302, isBuiltIn: true)

    private func external(points: Double, millimetres: Double?) -> DisplayMetrics {
        DisplayMetrics(pointWidth: points, pointHeight: points * 9 / 16, backingScale: 2, physicalWidthMM: millimetres, isBuiltIn: false)
    }

    func testAutoIsOneToOneOnTheBuiltInDisplayWhateverItsResolution() {
        XCTAssertEqual(InterfaceScale.autoFactor(for: builtIn), 1.0)
        var defaultResolution = builtIn
        defaultResolution.pointWidth = 1512
        XCTAssertEqual(InterfaceScale.autoFactor(for: defaultResolution), 1.0)
    }

    func testAutoIsOneToOneWhenTheDisplayCannotBeMeasured() {
        XCTAssertEqual(InterfaceScale.autoFactor(for: nil), 1.0)
        XCTAssertEqual(InterfaceScale.autoFactor(for: external(points: 2560, millimetres: nil)), 1.0)
        XCTAssertEqual(InterfaceScale.autoFactor(for: external(points: 2560, millimetres: 0)), 1.0)
    }

    func testAutoGoesALittleBiggerOnADeskDisplayAndStaysInRange() {
        // 27-inch 5K or 4K at "looks like 2560 x 1440": 109 pt/in, seen from 65 cm.
        XCTAssertEqual(InterfaceScale.autoFactor(for: external(points: 2560, millimetres: 597)), 1.1, accuracy: 0.001)
        // The same display set to larger text has physically larger points: never below 100%.
        XCTAssertEqual(InterfaceScale.autoFactor(for: external(points: 1920, millimetres: 597)), 1.0)
        // Set to "more space": capped at 125%.
        XCTAssertEqual(InterfaceScale.autoFactor(for: external(points: 3840, millimetres: 597)), 1.25)
    }

    func testAutoResolvesThroughFactor() {
        XCTAssertEqual(InterfaceScale.auto.factor(on: builtIn), 1.0)
        XCTAssertEqual(InterfaceScale.auto.factor(on: external(points: 2560, millimetres: 597)) ?? 0, 1.1, accuracy: 0.001)
    }

    // MARK: Preferences

    func testPreferencesAreWrittenWhereUIKitReadsThemAndReplacedCleanly() throws {
        let preferences = AppPreferences(containersDirectory: containers)
        let id = "com.example.scale"

        XCTAssertNil(try preferences.apply(nil, bundleID: id, display: builtIn), "no setting leaves the preferences alone")
        XCTAssertNil(preferences.storedFactor(bundleID: id))

        try preferences.apply(.percent115, bundleID: id, display: builtIn)
        XCTAssertEqual(preferences.storedFactor(bundleID: id) ?? 0, 1.15, accuracy: 0.0001)
        XCTAssertFalse(preferences.storedMacIdiom(bundleID: id))
        let plist = containers.appendingPathComponent("\(id)/Data/Library/Preferences/\(id).plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path), "the app's own preferences file, in its container")

        try preferences.apply(.macIdiom, bundleID: id, display: builtIn)
        XCTAssertNil(preferences.storedFactor(bundleID: id))
        XCTAssertTrue(preferences.storedMacIdiom(bundleID: id))

        try preferences.apply(.ipad, bundleID: id, display: builtIn)
        XCTAssertNil(preferences.storedFactor(bundleID: id))
        XCTAssertFalse(preferences.storedMacIdiom(bundleID: id))

        let line = try preferences.apply(.auto, bundleID: id, display: builtIn)
        XCTAssertEqual(preferences.storedFactor(bundleID: id), 1.0)
        XCTAssertEqual(line?.hasPrefix("Interface size: Auto, 100%"), true, line ?? "")
    }

    func testAnInvalidBundleIDNeverBecomesAPreferencesPath() {
        let preferences = AppPreferences(containersDirectory: containers)
        XCTAssertThrowsError(try preferences.apply(.percent100, bundleID: "../escape", display: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    // MARK: Operations

    private func operations() -> AppOperations {
        let paths = EiderPaths(home: home.appendingPathComponent("home", isDirectory: true))
        let library = LibraryStore(paths: paths)
        return AppOperations(
            sources: SourceStore(paths: paths), library: library, downloads: DownloadManager(paths: paths),
            installIPA: { _, _, _ in throw CancellationError() },
            uninstaller: Uninstaller(store: library, containersDirectory: containers),
            preferences: AppPreferences(containersDirectory: containers))
    }

    private func record(_ id: String, scale: InterfaceScale?, in ops: AppOperations) async throws {
        try await ops.library.record(InstalledApp(
            bundleID: id, name: id, version: "1", build: "1", path: home.appendingPathComponent("\(id).app"),
            options: InstallOptions(interfaceScale: scale)))
    }

    func testSettingAScaleRecordsItAndWritesItWithoutAReinstall() async throws {
        let ops = operations()
        try await record("com.example.a", scale: nil, in: ops)

        let change = try await ops.setInterfaceScale(.percent115, bundleID: "com.example.a", display: builtIn)

        XCTAssertEqual(change.app.options.interfaceScale, .percent115)
        let stored = try await ops.library.app(bundleID: "com.example.a")
        XCTAssertEqual(stored?.options.interfaceScale, .percent115)
        XCTAssertEqual(ops.preferences.storedFactor(bundleID: "com.example.a") ?? 0, 1.15, accuracy: 0.0001)
    }

    func testSettingAScaleOnAnAppThatIsNotInstalledSaysSo() async throws {
        do {
            _ = try await operations().setInterfaceScale(.auto, bundleID: "com.example.none", display: builtIn)
            XCTFail("expected a failure")
        } catch let failure as OperationFailure {
            XCTAssertEqual(failure.code, "operations.not_installed")
        }
    }

    func testAutoFollowsTheDisplayAndLeavesOtherSettingsAlone() async throws {
        let ops = operations()
        try await record("com.example.auto", scale: .auto, in: ops)
        try await record("com.example.fixed", scale: .percent85, in: ops)
        try await record("com.example.unset", scale: nil, in: ops)
        _ = try await ops.setInterfaceScale(.percent85, bundleID: "com.example.fixed", display: builtIn)

        let first = try await ops.refreshAutoInterfaceScales(display: builtIn)
        XCTAssertEqual(first, ["com.example.auto"])
        XCTAssertEqual(ops.preferences.storedFactor(bundleID: "com.example.auto"), 1.0)

        let again = try await ops.refreshAutoInterfaceScales(display: builtIn)
        XCTAssertEqual(again, [], "nothing to rewrite while the display is the same")

        let desk = external(points: 2560, millimetres: 597)
        let moved = try await ops.refreshAutoInterfaceScales(display: desk)
        XCTAssertEqual(moved, ["com.example.auto"])
        XCTAssertEqual(ops.preferences.storedFactor(bundleID: "com.example.auto") ?? 0, 1.1, accuracy: 0.0001)
        XCTAssertEqual(ops.preferences.storedFactor(bundleID: "com.example.fixed") ?? 0, 0.85, accuracy: 0.0001)
        XCTAssertNil(ops.preferences.storedFactor(bundleID: "com.example.unset"))
    }
}
