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
        if let plain = trimmedPlainASCII(text, keepingLineBreaks: false) { return plain }
        return filtered(text, keepingLineBreaks: false).trimmingCharacters(in: .whitespaces)
    }

    /// Longer prose (release notes, descriptions): line breaks and tabs survive,
    /// everything else `sanitized` removes does not.
    public static func sanitizedProse(_ text: String) -> String {
        if let plain = trimmedPlainASCII(text, keepingLineBreaks: true) { return plain }
        return filtered(text, keepingLineBreaks: true).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text from JSONSerialization is a bridged NSString, read one character per
    /// Objective-C call; one transcode to native UTF-8 first is cheaper (measured
    /// on 17k descriptions). ASCII scalars are judged without a property lookup,
    /// and text with nothing to remove is not rebuilt.
    private static func filtered(_ text: String, keepingLineBreaks: Bool) -> String {
        var native = text
        native.makeContiguousUTF8()
        func keep(_ scalar: Unicode.Scalar) -> Bool {
            guard scalar.isASCII else { return !isUnsafe(scalar) }
            if scalar.value >= 0x20 && scalar.value != 0x7F { return true }
            return keepingLineBreaks && (scalar == "\n" || scalar == "\t")
        }
        if native.unicodeScalars.allSatisfy(keep) { return native }
        return String(String.UnicodeScalarView(native.unicodeScalars.filter(keep)))
    }

    /// Most catalog text is printable ASCII, where nothing is unsafe and the only
    /// whitespace is the space (plus tab and newline in prose): the result is the
    /// text with those trimmed, found without the per-scalar property lookups and
    /// the Foundation trim. Nil for anything else, which takes the general path.
    private static func trimmedPlainASCII(_ text: String, keepingLineBreaks: Bool) -> String? {
        let space: UInt8 = 0x20, tab: UInt8 = 0x09, newline: UInt8 = 0x0A
        func isTrimmed(_ byte: UInt8) -> Bool { byte == space || (keepingLineBreaks && (byte == tab || byte == newline)) }
        var first: String.UTF8View.Index?
        var last: String.UTF8View.Index?
        let utf8 = text.utf8
        var index = utf8.startIndex
        while index != utf8.endIndex {
            let byte = utf8[index]
            let printable = byte >= space && byte < 0x7F
            guard printable || (keepingLineBreaks && (byte == tab || byte == newline)) else { return nil }
            if !isTrimmed(byte) {
                if first == nil { first = index }
                last = index
            }
            index = utf8.index(after: index)
        }
        guard let first, let last else { return "" }
        if first == utf8.startIndex, utf8.index(after: last) == utf8.endIndex { return text }
        return String(text[first...last])
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
