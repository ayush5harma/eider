import Foundation

/// The one validator for a bundle id wherever it arrives (an Info.plist, a
/// source, library.json, a command-line argument) or becomes a path (the
/// sandbox container, the downloads file name). An id is dot-separated,
/// non-empty components of `[A-Za-z0-9_-]` and starts with a letter or digit.
/// The old test accepted ".", and `eider uninstall . --remove-data` resolved
/// the container to ~/Library/Containers itself.
public enum BundleIdentifier {
    /// Apple allows 255; no real app comes near this.
    public static let maxLength = 155

    public static func isValid(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maxLength, let first = id.unicodeScalars.first, isAlphanumeric(first) else { return false }
        return id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "_" || $0 == "-" }
        }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }
}
