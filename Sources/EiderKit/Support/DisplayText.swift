import Foundation

/// Text that came from an IPA or a source is shown to people and used to build
/// file names, so it is cleaned where it enters the model. Control characters
/// (ESC starts a terminal sequence), NUL, line and paragraph separators and
/// format characters (the bidi overrides U+202A-202E and U+2066-2069 reorder
/// what a reader sees; zero-width characters hide) are removed.
public enum DisplayText {
    public static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    public static func containsUnsafe(_ text: String) -> Bool { text.unicodeScalars.contains(where: isUnsafe) }

    /// A name or version string: every unsafe character removed, ends trimmed.
    public static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isUnsafe($0) }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Longer prose (release notes, descriptions): line breaks and tabs survive,
    /// everything else `sanitized` removes does not.
    public static func sanitizedProse(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isUnsafe($0) || $0 == "\n" || $0 == "\t" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same text with each unsafe character written out as `\u{XX}`, for the
    /// terminal: newlines are kept, because callers use them as row breaks.
    public static func escapingControls(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" || !isUnsafe(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            }
        }
        return result
    }
}
