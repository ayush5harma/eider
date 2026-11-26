import Foundation

extension AppModel {
    // MARK: Interface size

    /// What the Library's menu shows as chosen: an app never set draws at UIKit's 77%.
    public func interfaceScale(of app: InstalledApp) -> InterfaceScale {
        app.options.interfaceScale ?? .ipad
    }

    /// Apps installed before the setting existed, still at the iPad's 77%.
    public var appsWithoutInterfaceScale: [InstalledApp] {
        installed.filter { $0.options.interfaceScale == nil }
    }

    /// The Library offers Auto for those apps until it is taken or declined.
    public var showsInterfaceScaleOffer: Bool {
        !appsWithoutInterfaceScale.isEmpty && settings.interfaceScaleOfferDismissed != true
    }

    public func setInterfaceScale(_ scale: InterfaceScale, for app: InstalledApp) async {
        do {
            let change = try await backend.setInterfaceScale(scale, bundleID: app.bundleID)
            interfaceScaleNotice = "\(app.name): \(change.message). Quit and reopen \(app.name) to see it."
        } catch {
            report(error)
        }
        await reload()
    }

    /// The offer's "Use Auto": every app without a setting goes to Auto.
    public func useAutoInterfaceScaleForUnsetApps() async {
        let apps = appsWithoutInterfaceScale
        var failed = false
        for app in apps {
            do { _ = try await backend.setInterfaceScale(.auto, bundleID: app.bundleID) } catch {
                failed = true
                report(error)
            }
        }
        if !failed {
            interfaceScaleNotice = apps.count == 1
                ? "\(apps[0].name) now uses Auto. Quit and reopen it to see it."
                : "\(apps.count) apps now use Auto. Quit and reopen them to see it."
        }
        await reload()
    }

    public func dismissInterfaceScaleOffer() {
        settings.interfaceScaleOfferDismissed = true
        do { try settings.save(to: paths) } catch { report(error) }
    }

    /// At launch: Auto follows the display Eider now runs on.
    public func refreshAutoInterfaceScales() async {
        do { _ = try await backend.refreshAutoInterfaceScales() } catch { report(error) }
    }
}
