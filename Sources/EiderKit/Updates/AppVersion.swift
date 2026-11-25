import Foundation

/// Version ordering for apps. App versions are dotted numbers in practice, so
/// every numeric run compares as a number (1.10 is newer than 1.9, which a text
/// comparison gets wrong) and a missing component counts as zero (1.0 equals
/// 1.0.0). A text run such as "beta" marks a prerelease: the same version
/// without it is newer.
///
/// A version that is not dotted-numeric ("8b6e503", "nightly", "beta") has no
/// order against another one and never outranks a numeric version: one source
/// in use lists LiveContainer 3.8.14 and, as a separate entry, a build named by
/// its commit hash, and reading that hash's leading 8 as a version number made
/// it an "update" from 3.8.14.
public enum AppVersion {
    private enum Token: Equatable {
        case number(UInt64)
        case text(String)
    }

    /// Numeric versions order numerically and beat any other kind; two other
    /// kinds are `.orderedSame` (the caller breaks that tie with a date, or keeps
    /// the source's order).
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftNumeric = isDottedNumeric(lhs), rightNumeric = isDottedNumeric(rhs)
        if leftNumeric != rightNumeric { return leftNumeric ? .orderedDescending : .orderedAscending }
        if !leftNumeric { return .orderedSame }
        let left = tokens(lhs), right = tokens(rhs)
        for index in 0..<max(left.count, right.count) {
            let order = compare(index < left.count ? left[index] : nil, index < right.count ? right[index] : nil)
            if order != .orderedSame { return order }
        }
        return .orderedSame
    }

    /// A release number: digits separated by dots, optionally with a leading "v",
    /// followed by nothing, by a separator or space ("1.2-beta", "3.8.14 (5)"), or,
    /// when there is at least one dot, by letters ("1.0b2"). "8b6e503" is a hash
    /// and "nightly" is a label: neither is.
    public static func isDottedNumeric(_ text: String) -> Bool {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if let first = rest.first, first == "v" || first == "V" { rest = rest.dropFirst() }
        var dots = 0
        var digits = 0
        while let character = rest.first {
            if character.isASCII, character.isNumber {
                digits += 1
                rest = rest.dropFirst()
            } else if character == ".", digits > 0, let after = rest.dropFirst().first, after.isASCII, after.isNumber {
                dots += 1
                digits = 0
                rest = rest.dropFirst()
            } else {
                break
            }
        }
        guard digits > 0 else { return false }
        guard let next = rest.first else { return true }
        return !(next.isLetter || next.isNumber) || dots > 0
    }

    /// Is `version`/`build` strictly newer than `installedVersion`/`installedBuild`?
    /// The build number only breaks a tie between equal versions, and only when
    /// both sides have one, so a source that omits it never causes an update.
    public static func isNewer(version: String, build: String?, than installedVersion: String, build installedBuild: String?) -> Bool {
        let order = compare(version, installedVersion)
        if order != .orderedSame { return order == .orderedDescending }
        guard let build, let installedBuild, !build.isEmpty, !installedBuild.isEmpty else { return false }
        return compare(build, installedBuild) == .orderedDescending
    }

    // MARK: Internals

    /// A token missing on one side is zero against a number and newer than a
    /// prerelease marker; a number beats text at the same position.
    private static func compare(_ lhs: Token?, _ rhs: Token?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case let (nil, right?):
            if case .text = right { return .orderedDescending }
            return compare(.number(0), right)
        case let (left?, nil):
            return invert(compare(nil, left))
        case let (.number(a)?, .number(b)?):
            return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case let (.text(a)?, .text(b)?):
            return a.compare(b, options: .caseInsensitive)
        case (.number?, .text?):
            return .orderedDescending
        case (.text?, .number?):
            return .orderedAscending
        }
    }

    private static func invert(_ order: ComparisonResult) -> ComparisonResult {
        switch order {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private static func tokens(_ text: String) -> [Token] {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespaces))
        if let first = trimmed.first, first == "v" || first == "V", trimmed.dropFirst().first?.isNumber == true {
            trimmed = trimmed.dropFirst()
        }
        var result: [Token] = []
        var run = ""
        var runIsNumber = false
        func flush() {
            guard !run.isEmpty else { return }
            result.append(runIsNumber ? .number(UInt64(run) ?? .max) : .text(run))
            run = ""
        }
        for character in trimmed {
            guard character.isASCII, character.isLetter || character.isNumber else { flush(); continue }
            if !run.isEmpty, character.isNumber != runIsNumber { flush() }
            runIsNumber = character.isNumber
            run.append(character)
        }
        flush()
        return result
    }
}
