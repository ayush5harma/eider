import Foundation

/// The app-group ids an IPA's own signature asks for. They are the only
/// entitlement carried over to the ad hoc signature: apps such as iSH read
/// their group id from their own signature and crash when it is missing, while
/// the keys tied to a team (application-identifier, keychain-access-groups)
/// would get an ad hoc app killed. A group id reaches a file path in the
/// app-group shim, so each is held to a strict shape.
public enum AppGroups {
    public static let entitlementKey = "com.apple.security.application-groups"
    static let maxCount = 32
    static let maxBytes = 255

    public struct Result: Equatable, Sendable {
        public let groups: [String]
        /// Entries refused: not a string, a bad shape, or past the cap. Repeats are merged silently.
        public let dropped: Int
    }

    /// Letters, digits, '.', '-' and '_'; starts with a letter or digit; no "..".
    static func isValid(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...maxBytes).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        let allowed = bytes.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
        return allowed && !id.contains("..")
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// The valid, distinct ids of an entitlements dictionary (at most `maxCount`).
    public static func filter(_ entitlements: [String: Any]?) -> Result {
        guard let value = entitlements?[entitlementKey] else { return Result(groups: [], dropped: 0) }
        guard let entries = value as? [Any] else { return Result(groups: [], dropped: 1) }
        var groups: [String] = []
        var dropped = 0
        for entry in entries {
            guard let id = entry as? String, isValid(id), groups.count < maxCount || groups.contains(id) else {
                dropped += 1
                continue
            }
            if !groups.contains(id) { groups.append(id) }
        }
        return Result(groups: groups, dropped: dropped)
    }

    /// Read from an executable as shipped, before conversion rewrites it.
    public static func read(from executable: URL) -> Result {
        filter(MachOEntitlements.read(at: executable))
    }
}
