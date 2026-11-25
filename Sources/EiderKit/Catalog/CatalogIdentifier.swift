import Foundation

/// What a source calls an app (`bundleIdentifier`, PlayCover's `bundleID`).
/// It is a label for showing and matching, not the installed app's identity:
/// sources in the wild list ids like `cypwn.Adobe_Express_11.3.0+Satella.11.3.0`,
/// `sh.ppy.osu!lazer` or `com.unknown.` (18 of them in one 17,430-app source,
/// 2026-11-26), and skipping those hid apps that other clients list fine.
///
/// So it is only cleaned for display (control, format and bidi characters
/// removed) and bounded, and `BundleIdentifier.isValid` applies where an id
/// becomes a path or a signing input instead: the installed app takes the IPA's
/// own validated `CFBundleIdentifier` (or the owner's validated `--bundle-id`),
/// and the downloads folder names a file after a catalog id only when it passes
/// the strict check (`DownloadManager.fileName`). A catalog id is compared with
/// the IPA's id, which a malformed one can never equal, so such an entry installs
/// only with the owner's explicit `--bundle-id`.
public enum CatalogIdentifier {
    /// Apple's limit for a real bundle id; anything longer is not an app's name for itself.
    public static let maxBytes = 255
    private static let quotedPrefix = 60

    /// Whether `text` is something a source may list as an id: what a lookup by
    /// catalog id (`eider info`) accepts. Never a test for use as a path.
    public static func isListable(_ text: String) -> Bool {
        !text.isEmpty && !isTooLong(text) && !DisplayText.containsUnsafe(text)
    }

    /// The id as given, minus what `DisplayText` removes; nil when nothing is left.
    static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = DisplayText.sanitized(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func isTooLong(_ id: String) -> Bool { id.utf8.count > maxBytes }

    /// For a warning line: an over-long id is cut rather than quoted whole.
    static func quoted(_ id: String) -> String {
        isTooLong(id) ? String(id.prefix(quotedPrefix)) + "..." : id
    }
}
