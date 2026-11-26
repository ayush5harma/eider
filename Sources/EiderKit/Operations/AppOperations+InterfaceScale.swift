import Foundation

/// One app's interface size as recorded and as its preferences hold it now.
public struct InterfaceScaleState: Sendable, Equatable, Encodable {
    /// nil: never set (installed before 0.1.9), so UIKit's 77% applies.
    public let setting: InterfaceScale?
    /// The factor in the app's preferences; nil means UIKit's default.
    public let factor: Double?
    public let macIdiom: Bool

    public var summary: String {
        if macIdiom { return "Mac idiom (1:1)" }
        let percent = Int(((factor ?? 0.77) * 100).rounded())
        guard let setting else {
            return factor == nil ? "not set (77%, UIKit's iPad default)" : "not set by Eider (its preferences say \(percent)%)"
        }
        return setting == .auto ? "Auto (\(percent)% now)" : "\(setting.label)"
    }
}

/// The result of changing one app's interface size.
public struct InterfaceScaleChange: Sendable, Equatable {
    public let app: InstalledApp
    /// What the app will do at its next launch, for showing.
    public let message: String
}

extension AppOperations {
    /// Records `scale` for the installed app and writes it into the app's
    /// preferences, with no reinstall: the app picks it up at its next launch.
    /// `display` is what Auto is worked out for (the main display by default).
    public func setInterfaceScale(
        _ scale: InterfaceScale, bundleID: String, display: DisplayMetrics? = .main()
    ) async throws -> InterfaceScaleChange {
        do {
            guard let installed = try await library.app(bundleID: bundleID) else { throw OperationFailure.notInstalled(bundleID) }
            let message = try preferences.apply(scale, bundleID: installed.bundleID, display: display) ?? scale.label
            var options = installed.options
            options.interfaceScale = scale
            let updated = installed.replacingOptions(options)
            try await library.record(updated)
            return InterfaceScaleChange(app: updated, message: message)
        } catch {
            throw OperationFailure.wrap(error)
        }
    }

    public func interfaceScaleState(bundleID: String) async throws -> InterfaceScaleState {
        do {
            guard let installed = try await library.app(bundleID: bundleID) else { throw OperationFailure.notInstalled(bundleID) }
            return InterfaceScaleState(
                setting: installed.options.interfaceScale,
                factor: preferences.storedFactor(bundleID: bundleID),
                macIdiom: preferences.storedMacIdiom(bundleID: bundleID))
        } catch {
            throw OperationFailure.wrap(error)
        }
    }

    /// Apps set to Auto whose stored factor no longer matches `display` (the
    /// main display changed since it was applied) get the new factor. Returns
    /// the ids it rewrote; cheap enough to run at every launch of Eider.
    @discardableResult
    public func refreshAutoInterfaceScales(display: DisplayMetrics? = .main()) async throws -> [String] {
        do {
            let wanted = InterfaceScale.autoFactor(for: display)
            var changed: [String] = []
            for app in try await library.all() where app.options.interfaceScale == .auto {
                if let stored = preferences.storedFactor(bundleID: app.bundleID), abs(stored - wanted) < 0.001 { continue }
                try preferences.apply(.auto, bundleID: app.bundleID, display: display)
                changed.append(app.bundleID)
            }
            return changed
        } catch {
            throw OperationFailure.wrap(error)
        }
    }
}

extension InstalledApp {
    /// The same record with other options (the library's record of a setting
    /// changed after install).
    func replacingOptions(_ options: InstallOptions) -> InstalledApp {
        InstalledApp(
            bundleID: bundleID, name: name, version: version, build: build, path: path,
            sourceURL: sourceURL, origin: origin, ipaSHA256: ipaSHA256, options: options,
            installedAt: installedAt, engineVersion: engineVersion)
    }
}
