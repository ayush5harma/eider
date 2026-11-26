import Foundation
import XCTest
@testable import EiderKit

@MainActor
final class AppModelInterfaceScaleTests: XCTestCase {
    private typealias F = AppModelFixtures

    private func model(_ apps: [InstalledApp]) async throws -> (AppModel, StubBackend, EiderPaths) {
        let paths = try CatalogFixtures.temporaryHome()
        let backend = StubBackend()
        backend.setInstalled(apps)
        let model = AppModel(paths: paths, backend: backend)
        await model.reload()
        return (model, backend, paths)
    }

    private func app(_ id: String, scale: InterfaceScale?) -> InstalledApp {
        InstalledApp(bundleID: id, name: id, version: "1", build: "1", path: URL(fileURLWithPath: "/tmp/\(id).app"),
                     options: InstallOptions(interfaceScale: scale))
    }

    func testNewInstallsStartOnAuto() {
        XCTAssertEqual(InstallOptionsDraft(destination: InstallOptions.defaultDestination).options().interfaceScale, .auto)
    }

    func testAppsFromBeforeTheSettingAreOfferedAutoAndOnlyThoseAreChanged() async throws {
        let (model, backend, _) = try await model([app("com.old", scale: nil), app("com.new", scale: .percent115)])
        XCTAssertEqual(model.appsWithoutInterfaceScale.map(\.bundleID), ["com.old"])
        XCTAssertTrue(model.showsInterfaceScaleOffer)
        let byID = Dictionary(uniqueKeysWithValues: model.installed.map { ($0.bundleID, $0) })
        XCTAssertEqual(model.interfaceScale(of: try XCTUnwrap(byID["com.new"])), .percent115)
        XCTAssertEqual(model.interfaceScale(of: try XCTUnwrap(byID["com.old"])), .ipad, "never set reads as the iPad's 77%")

        await model.useAutoInterfaceScaleForUnsetApps()

        XCTAssertEqual(backend.interfaceScaleCalls.map(\.1), ["com.old"])
        XCTAssertEqual(backend.interfaceScaleCalls.map(\.0), [.auto])
        XCTAssertFalse(model.showsInterfaceScaleOffer)
        XCTAssertNotNil(model.interfaceScaleNotice)
    }

    func testNotNowIsRemembered() async throws {
        let (model, _, paths) = try await model([app("com.old", scale: nil)])
        model.dismissInterfaceScaleOffer()
        XCTAssertFalse(model.showsInterfaceScaleOffer)
        XCTAssertEqual(AppSettings.load(from: paths).interfaceScaleOfferDismissed, true)
    }

    func testASettingsFileWithoutTheAnswerStillReads() throws {
        let paths = try CatalogFixtures.temporaryHome()
        try paths.ensure()
        try Data(#"{"defaultInstallLocation":"file:///Applications/Games/"}"#.utf8).write(to: AppSettings.file(in: paths))
        let settings = AppSettings.load(from: paths)
        XCTAssertEqual(settings.defaultInstallLocation.path, "/Applications/Games")
        XCTAssertNil(settings.interfaceScaleOfferDismissed)
    }

    func testChangingOneAppSaysWhenItApplies() async throws {
        let (model, backend, _) = try await model([app("com.one", scale: .auto)])
        await model.setInterfaceScale(.macIdiom, for: model.installed[0])
        XCTAssertEqual(backend.interfaceScaleCalls.first?.0, .macIdiom)
        XCTAssertEqual(model.installed.first?.options.interfaceScale, .macIdiom)
        XCTAssertTrue(model.interfaceScaleNotice?.contains("Quit and reopen com.one") == true, model.interfaceScaleNotice ?? "")
    }
}
