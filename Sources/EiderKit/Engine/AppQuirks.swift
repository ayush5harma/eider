import Foundation

/// One workaround for an app's own code under Mac Catalyst: the instance
/// method `selector` of `className`, a BOOL getter with no arguments, answers
/// `returns` instead of running. Applied by the quirks shim
/// (Shims/ipa-quirks.m), which skips a row whose class or method the running
/// app does not have, or whose method is not a BOOL getter, so a new app
/// version without them is left alone.
public struct AppQuirk: Equatable, Sendable {
    /// The IPA's own id (`BundleIdentity.shippedID`): a quirk is about the
    /// app's code, which `--bundle-id` does not change.
    public let bundleID: String
    public let className: String
    public let selector: String
    public let returns: Bool
    /// What goes wrong without the row and what was measured; for the reader
    /// of this table, never written into the bundle.
    public let why: String

    /// An Objective-C identifier: a letter or '_', then letters, digits and
    /// '_', at most 255 bytes. A class name and a BOOL getter's selector are
    /// both this shape; anything else in a row is a typo.
    static func isPlainName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...255).contains(bytes.count) else { return false }
        func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || b == 95 }
        return letter(bytes[0]) && bytes.allSatisfy { letter($0) || (48...57).contains($0) }
    }
}

/// The table of per-app workarounds. Adding an app is adding a row here: the
/// installer links the quirks shim into an app whose shipped bundle id has a
/// row and writes that app's rows into the bundle (`fileName`), and the shim
/// applies what it reads. No shim code changes. See docs/ARCHITECTURE.md.
public enum AppQuirks {
    public static let all: [AppQuirk] = [
        AppQuirk(
            bundleID: "com.google.ios.youtube",
            className: "YTColdConfig",
            selector: "mainAppCoreClientIos27SceneDelegateLaunchSequenceFixEnabled",
            returns: true,
            why: """
                Blank window. YouTube builds its root view controller on the main queue \
                right after launch and installs it into the window its scene delegate made; \
                under Catalyst the first scene connects 0.5-2.3 s later (macOS 27.3, YouTube \
                21.47.6, 2026-11-26), the controller finds no window and the window stays \
                empty ("Attempt to present ... whose view is not in the window hierarchy", \
                8 accessibility elements). This server-gated switch is YouTube's own fix for \
                a late scene; with it on, 79 elements and the sign-in sheet.
                """),
        // The end-to-end probe (legacy/test/probe.m), so Scripts/engine-e2e.sh
        // proves the whole path: linked, written, sealed, applied, and a row
        // naming a method that is not a BOOL getter left alone.
        AppQuirk(
            bundleID: "local.ipa-install-on-mac.probe", className: "ProbeQuirkTarget", selector: "probeQuirkSwitch",
            returns: true, why: "Test row: the probe logs YES only if the shim applied it."),
        AppQuirk(
            bundleID: "local.ipa-install-on-mac.probe", className: "ProbeQuirkTarget", selector: "probeQuirkCount",
            returns: true, why: "Test row: an NSInteger getter, which the shim must refuse to replace."),
    ]

    /// The file the shim reads, at the root of the app bundle (the main
    /// bundle's resource directory in the iOS layout the installer keeps).
    public static let fileName = "EiderQuirks.plist"

    /// The rows for an app, chosen by exact bundle id.
    public static func rows(for bundleID: String) -> [AppQuirk] {
        all.filter { $0.bundleID == bundleID }
    }

    /// Writes `rows` as the shim reads them, an array of {class, selector,
    /// returns}, into `app`. Whatever the IPA shipped under that name, a
    /// file or a symlink, is removed first, never followed. Must run before
    /// signing, so the signature seals it.
    @discardableResult
    static func write(_ rows: [AppQuirk], into app: URL) throws -> URL {
        let url = app.appendingPathComponent(fileName)
        let plist = rows.map { ["class": $0.className, "selector": $0.selector, "returns": $0.returns] as [String: Any] }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            try FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}
