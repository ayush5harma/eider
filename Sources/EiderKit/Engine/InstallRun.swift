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
    private let onEvent: @Sendable (InstallEvent) -> Void

    private var plist: InfoPlist!
    private var identity: BundleIdentity!
    private var converter: BundleConverter!
    private var app: URL!

    init(ipa: URL, options: InstallOptions, shims: ShimLocator, extractor: IPAExtractor, reset: DataReset, onEvent: @escaping @Sendable (InstallEvent) -> Void) {
        self.ipa = ipa
        self.options = options
        self.shims = shims
        self.extractor = extractor
        self.reset = reset
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
        let linksOpenGLES = machOs.contains { file in
            ((try? MachOFiles.readImage(at: file).linkedDylibs()) ?? []).contains { $0.contains("/OpenGLES.framework/") }
        }
        try convert(machOs)
        try editBundle()
        let linked = try link(openGLES: linksOpenGLES, extras: extras)
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
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent(identity.executable).path) else {
            throw InstallFailure(.badBundle, "The executable \(identity.executable) is not in the bundle.")
        }
        if options.resetData { try reset.refuseIfRunning(name: identity.name) }
        emit(.validate, "\(identity.name) (\(identity.bundleID)), executable \(identity.executable), iOS \(identity.minimumOS ?? "?")+", 0.22)
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
        if let name = options.displayName {
            plist.set("CFBundleDisplayName", name)
            plist.set("CFBundleName", name)
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

    /// Link what the app needs into the main executable, in the legacy order:
    /// the keychain shim, the OpenGL ES redirect (only for apps that link
    /// OpenGL ES), the app-group shim (always), then extra libraries.
    private func link(openGLES: Bool, extras: [(source: URL, name: String)]) throws -> [URL] {
        emit(.link, "Linking helper libraries", 0.66)
        let linker = ShimLinker(app: app, executable: executableURL)
        var added: [URL] = []
        var wanted: [(Shim, String)] = []
        if options.keychainShim { wanted.append((.keychain, "the keychain shim")) }
        if openGLES { wanted.append((.gles, "the OpenGL ES shim")) }
        wanted.append((.groups, "the app-group shim"))
        for (shim, label) in wanted {
            added.append(try linker.link(try shims.url(for: shim), as: shim.rawValue, installName: shim.installName, label: label))
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
        try signer.sign(machOs: machOs)
        emit(.verify, "Verifying signatures", 0.9)
        try signer.verify(machOs: machOs)
        BundleSigner.clearQuarantine(under: app)
    }

    // MARK: Place

    private func place() throws -> InstalledApp {
        emit(.place, "Installing into \(options.destination.path)", 0.94)
        let destination = options.destination
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) } catch {
            throw InstallFailure(.destinationUnusable, "Cannot create \(destination.path): \(error.localizedDescription)")
        }
        guard FileManager.default.isWritableFile(atPath: destination.path) else {
            throw InstallFailure(.destinationUnusable, "\(destination.path) is not writable. Choose another folder.")
        }
        let target = destination.appendingPathComponent("\(identity.name).app", isDirectory: true)
        try moveExistingCopyAside(target)
        if options.resetData, let note = reset.clear(bundleID: identity.bundleID) { emit(.place, note, 0.96) }
        do { try FileManager.default.moveItem(at: app, to: target) } catch {
            throw InstallFailure(.placementFailed, "Could not move the app into \(destination.path): \(error.localizedDescription)")
        }
        _ = try? ProcessRunner.run(Self.lsregister, ["-f", target.path])
        return InstalledApp(
            bundleID: identity.bundleID, name: identity.name,
            version: plist.string("CFBundleShortVersionString") ?? "", build: plist.string("CFBundleVersion") ?? "",
            path: target, sourceURL: options.sourceURL, ipaSHA256: options.ipaSHA256, options: options
        )
    }

    /// A same-named bundle with another bundle id is somebody else's app: leave
    /// it unless asked. Either way the old copy goes to the Trash, not the bin.
    private func moveExistingCopyAside(_ target: URL) throws {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let old = ["Info.plist", "Contents/Info.plist"].lazy
            .compactMap { try? InfoPlist(url: target.appendingPathComponent($0)) }.first?.string("CFBundleIdentifier")
        if old != identity.bundleID, !options.force {
            throw InstallFailure(
                .destinationConflict,
                "\(target.path) already exists with bundle id \(old ?? "unknown"), not \(identity.bundleID). Use force to replace it, or choose another destination."
            )
        }
        do { _ = try Trash.move(target) } catch {
            do { try FileManager.default.removeItem(at: target) } catch {
                throw InstallFailure(.placementFailed, "Cannot replace \(target.path): \(error.localizedDescription)")
            }
            emit(.warning, "Could not use the Trash; the previous copy was deleted.", 0.95)
        }
        emit(.place, "Previous copy moved to the Trash", 0.95)
    }
}
