import Foundation

/// One install, start to finish, in the legacy installer's order. Synchronous
/// on purpose: it is a pipeline of file edits and child processes, run on a
/// background queue by `Installer.install`.
final class InstallRun: @unchecked Sendable {
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    private static let macIdiomFamily = 6

    private let ipa: URL
    private let options: InstallOptions
    private let shims: ShimLocator
    private let extractor: IPAExtractor
    private let reset: DataReset
    private let recorded: [InstalledApp]
    private let onEvent: @Sendable (InstallEvent) -> Void

    private var plist: InfoPlist!
    private var identity: BundleIdentity!
    private var converter: BundleConverter!
    private var app: URL!
    /// The IPA's own app-group ids, read before conversion; the signature carries them.
    private var appGroups: [String] = []

    init(ipa: URL, options: InstallOptions, shims: ShimLocator, extractor: IPAExtractor, reset: DataReset, recorded: [InstalledApp] = [], onEvent: @escaping @Sendable (InstallEvent) -> Void) {
        self.ipa = ipa
        self.options = options
        self.shims = shims
        self.extractor = extractor
        self.reset = reset
        self.recorded = recorded
        self.onEvent = onEvent
    }

    private func emit(_ step: InstallStep, _ message: String, _ fraction: Double) {
        onEvent(InstallEvent(step: step, message: message, fraction: fraction))
    }

    // MARK: Pipeline

    func execute() throws -> InstalledApp {
        let extras = try options.extraDylibs.map { (source: $0, name: try ShimLinker.extraLibraryName(for: $0)) }
        for source in options.extraDylibs where !FileManager.default.isReadableFile(atPath: source.path) {
            throw InstallFailure(.invalidOption, "The library \(source.path) does not exist.")
        }
        // Every install links the app-group shim, and most the keychain one:
        // find them before any work, not after.
        _ = try shims.url(for: .groups)
        if options.keychainShim { _ = try shims.url(for: .keychain) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("eider-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }

        try unpack(into: work)
        try validateBundle()
        if options.removeExtensions { removeExtensions() }
        try neutraliseTweaks()
        let machOs = converter.machOFiles()
        guard !machOs.isEmpty else { throw InstallFailure(.noMachO, "No Mach-O binaries were found in the bundle, so there is nothing to convert.") }
        try refuseEncrypted(machOs)
        // Read before conversion, which rewrites load commands but keeps these.
        let linkedDylibs = machOs.flatMap { (try? MachOFiles.readImage(at: $0).linkedDylibs()) ?? [] }
        readAppGroups()
        try convert(machOs)
        try editBundle()
        let linked = try link(linkedDylibs: linkedDylibs, extras: extras)
        try sign(machOs + linked, work: work)
        return try place()
    }

    // MARK: Stages

    private func unpack(into work: URL) throws {
        emit(.unpack, "Unpacking \(ipa.lastPathComponent)", 0.02)
        app = try extractor.extract(ipa, into: work.appendingPathComponent("x", isDirectory: true))
        converter = BundleConverter(app: app)
    }

    private func validateBundle() throws {
        emit(.validate, "Reading the app's Info.plist", 0.2)
        plist = try InfoPlist(url: app.appendingPathComponent("Info.plist"))
        identity = try BundleIdentity(plist: plist, options: options)
        try checkExpectedBundleID()
        try checkReplacedBundleID()
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent(identity.executable).path) else {
            throw InstallFailure(.badBundle, "The executable \(identity.executable) is not in the bundle.")
        }
        if options.resetData { try reset.refuseIfRunning(name: identity.name) }
        emit(.validate, "\(identity.name) (\(identity.bundleID)), executable \(identity.executable), iOS \(identity.minimumOS ?? "?")+", 0.22)
    }

    /// A catalog entry's id is a listing key, not a promise: real sources list
    /// entries such as "cypwn.AppCake+.7.2.2" whose IPA ships another id, and
    /// refusing them (0.1.1) made those entries uninstallable while Feather
    /// installs them. The app is installed under its own id (or the override),
    /// with a warning naming both. What still guards the user's apps: AppPlacer
    /// replaces a bundle at the destination only when Eider placed it.
    private func checkExpectedBundleID() throws {
        guard let expected = options.expectedBundleID, identity.shippedID != expected, identity.shippedID != options.bundleID else { return }
        emit(.warning, "The source lists \(expected), but this IPA is \(identity.shippedID); installing it as \(identity.bundleID).", 0.21)
    }

    /// An update replaces the installed app or nothing: an IPA that now ships
    /// another id would otherwise be placed beside it as a second app.
    private func checkReplacedBundleID() throws {
        guard let replacing = options.replacingBundleID, identity.bundleID != replacing else { return }
        throw InstallFailure(
            .bundleIDMismatch,
            "This update is \(identity.bundleID), but the installed app is \(replacing); nothing was changed. Install it separately if you want both.")
    }

    /// App extensions are a frequent reason a sideloaded app fails to launch or
    /// to sign; dropping them before conversion also saves converting them.
    private func removeExtensions() {
        let plugIns = app.appendingPathComponent("PlugIns", isDirectory: true)
        let extensions = ((try? FileManager.default.contentsOfDirectory(atPath: plugIns.path)) ?? []).filter { $0.hasSuffix(".appex") }
        for name in extensions { try? FileManager.default.removeItem(at: plugIns.appendingPathComponent(name)) }
        if !extensions.isEmpty { emit(.validate, "Removed \(extensions.count) app extension(s)", 0.23) }
    }

    /// A tweak that hooks the keychain steals the calls the keychain shim exists
    /// for, so each is replaced by an empty library of the same install name.
    private func neutraliseTweaks() throws {
        guard options.keychainShim else { return }
        let replaced = try converter.neutraliseKeychainFixes { try self.shims.url(for: .neutralised) }
        if !replaced.isEmpty { emit(.neutralise, "Neutralised keychain-fix tweak(s): \(replaced.joined(separator: ", "))", 0.25) }
    }

    private func refuseEncrypted(_ machOs: [URL]) throws {
        emit(.scan, "Checking \(machOs.count) binaries for FairPlay encryption", 0.27)
        let encrypted = converter.encryptedBinaries(machOs)
        guard encrypted.isEmpty else {
            throw InstallFailure(
                .encrypted,
                "\(identity.name) is still FairPlay-encrypted (an App Store copy): \(encrypted.joined(separator: ", ")). Decrypt it first; Eider cannot remove FairPlay."
            )
        }
    }

    /// Apps such as iSH parse their own signature for the group id and crash when
    /// it is missing, so the app's application-groups entitlement (and nothing
    /// else of the original) is signed back in. The ids reach file paths in the
    /// app-group shim, so `AppGroups` drops any that are not plain names.
    private func readAppGroups() {
        let result = AppGroups.read(from: executableURL)
        appGroups = result.groups
        if !result.groups.isEmpty { emit(.validate, "Keeping the app's app group(s): \(result.groups.joined(separator: ", "))", 0.28) }
        if result.dropped > 0 {
            emit(.warning, "Dropped \(result.dropped) app-group id(s) from the app's entitlements that are not plain names.", 0.28)
        }
    }

    private func convert(_ machOs: [URL]) throws {
        for (index, file) in machOs.enumerated() {
            emit(.convert, "Converting \(converter.relative(file)) to Mac Catalyst", 0.3 + 0.3 * Double(index) / Double(machOs.count))
            if let warning = try converter.convert(file) { emit(.warning, warning, 0.6) }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try? FileManager.default.removeItem(at: app.appendingPathComponent("embedded.mobileprovision"))
    }

    private var executableURL: URL { app.appendingPathComponent(identity.executable) }

    /// Info.plist edits: MinimumOSVersion (LaunchServices reads it as a system
    /// requirement once the platform says Catalyst, so an iOS 17 app would
    /// otherwise "need macOS 17"), the Mac idiom, and the name and id overrides.
    private func editBundle() throws {
        emit(.edit, "Editing Info.plist", 0.62)
        if let minimum = identity.minimumOS.flatMap(MachOVersion.init), minimum > BundleConverter.minimumOS {
            plist.set("MinimumOSVersion", "11.0")
        }
        if options.macIdiom { plist.set("UIDeviceFamily", Self.familiesWithMac(plist.integers("UIDeviceFamily"))) }
        if options.displayName != nil {
            plist.set("CFBundleDisplayName", identity.displayName)
            plist.set("CFBundleName", identity.displayName)
        }
        if options.bundleID != nil { plist.set("CFBundleIdentifier", identity.bundleID) }
        do { try plist.write() } catch {
            throw InstallFailure(.badBundle, "Could not write the app's Info.plist: \(error.localizedDescription)")
        }
    }

    /// UIKit decides the idiom from UIDeviceFamily at launch; 6 is Mac. Appended,
    /// never replaced, so an iPhone-only app keeps its 1.
    static func familiesWithMac(_ families: [Int]?) -> [Int] {
        guard let families else { return [1, 2, macIdiomFamily] }
        return families.contains(macIdiomFamily) ? families : families + [macIdiomFamily]
    }

    /// Link what the app needs into the main executable, in the legacy order
    /// (`ShimLinker.shimsToLink`), then extra libraries.
    private func link(linkedDylibs: [String], extras: [(source: URL, name: String)]) throws -> [URL] {
        emit(.link, "Linking helper libraries", 0.66)
        let linker = ShimLinker(app: app, executable: executableURL)
        var added: [URL] = []
        // The IPA's own id: a quirk is about the app's code, which --bundle-id does not change.
        let wanted = ShimLinker.shimsToLink(keychain: options.keychainShim, linkedDylibs: linkedDylibs, bundleID: identity.shippedID)
        for (shim, label) in wanted {
            added.append(try linker.link(try shims.url(for: shim), as: shim.rawValue, installName: shim.installName, label: label))
        }
        if wanted.contains(where: { $0.shim == .quirks }) {
            let rows = AppQuirks.rows(for: identity.shippedID)
            do { try AppQuirks.write(rows, into: app) } catch {
                throw InstallFailure(.badBundle, "Could not write the app's quirk table: \(error.localizedDescription)")
            }
            emit(.link, "Applying \(rows.count) workaround(s) for \(identity.shippedID)", 0.68)
        }
        for extra in extras {
            let installName = "@executable_path/Frameworks/\(extra.name)"
            added.append(try linker.link(extra.source, as: extra.name, installName: installName, label: extra.name) { copy in
                if let warning = try self.converter.convert(copy) { self.emit(.warning, warning, 0.7) }
            })
        }
        return added
    }

    private func sign(_ machOs: [URL], work: URL) throws {
        emit(.sign, "Signing \(machOs.count) binaries (ad hoc)", 0.72)
        let signer = BundleSigner(app: app, workDirectory: work, relative: converter.relative)
        try signer.sign(machOs: machOs, appGroups: appGroups, warn: { [weak self] in self?.emit(.warning, $0, 0.85) })
        emit(.verify, "Verifying signatures", 0.9)
        try signer.verify(machOs: machOs)
        BundleSigner.clearQuarantine(under: app)
    }

    // MARK: Place

    private func place() throws -> InstalledApp {
        emit(.place, "Installing into \(options.destination.path)", 0.94)
        let placer = AppPlacer(
            force: options.force, resetData: options.resetData, reset: reset, recorded: recorded,
            emit: { [onEvent] message, fraction in onEvent(InstallEvent(step: .place, message: message, fraction: fraction)) })
        let target = try placer.place(app, name: identity.name, bundleID: identity.bundleID, into: options.destination)
        _ = try? ProcessRunner.run(Self.lsregister, ["-f", target.path])
        return InstalledApp(
            bundleID: identity.bundleID, name: identity.name,
            version: plist.string("CFBundleShortVersionString").map(DisplayText.sanitized) ?? "",
            build: plist.string("CFBundleVersion").map(DisplayText.sanitized) ?? "",
            path: target, sourceURL: options.sourceURL, origin: options.origin, ipaSHA256: options.ipaSHA256, options: options
        )
    }
}
