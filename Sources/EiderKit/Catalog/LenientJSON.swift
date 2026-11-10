import Foundation

typealias JSONDict = [String: Any]

/// Accessors that accept what sloppy hand-written sources actually contain:
/// numbers where strings belong, strings where numbers belong, blank strings.
extension Dictionary where Key == String, Value == Any {
    /// First non-blank value among `keys`, trimmed. Numbers become their text.
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let text = LenientJSON.text(self[key]) { return text }
        }
        return nil
    }

    /// Like `string`, for a name or version that is shown: control, format and
    /// bidi characters are removed. Nil when nothing is left.
    func displayName(_ keys: String...) -> String? {
        for key in keys {
            if let text = LenientJSON.text(self[key]) {
                let cleaned = DisplayText.sanitized(text)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    /// Like `string`, for prose: line breaks survive, the rest of what `displayName` removes does not.
    func prose(_ keys: String...) -> String? {
        for key in keys {
            if let text = LenientJSON.text(self[key]) {
                let cleaned = DisplayText.sanitizedProse(text)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    func int64(_ key: String) -> Int64? {
        switch self[key] {
        case let number as NSNumber where !LenientJSON.isBoolean(number):
            let double = number.doubleValue
            guard double.isFinite, double >= 0, double < 9.2e18 else { return nil }
            return Int64(double)
        case let text as String:
            return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    func dictionary(_ key: String) -> JSONDict? { self[key] as? JSONDict }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
}

enum LenientJSON {
    static func text(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber where !isBoolean(number):
            return number.stringValue
        default:
            return nil
        }
    }

    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Strips a UTF-8 byte-order mark, which some editors add and which
    /// JSONSerialization is not guaranteed to accept.
    static func object(from data: Data) throws -> Any {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = data.starts(with: bom) ? data.dropFirst(bom.count) : data[...]
        do {
            return try JSONSerialization.jsonObject(with: Data(body), options: [.fragmentsAllowed])
        } catch {
            throw CatalogFailure.notJSON
        }
    }

    /// 64 hex characters, lower-cased, or nil.
    static func sha256(_ raw: String?) -> String? {
        guard let raw, raw.count == 64, raw.allSatisfy(\.isHexDigit) else { return nil }
        return raw.lowercased()
    }
}

/// Dates as real sources write them: ISO 8601 with or without fractional
/// seconds or zone, a space instead of the T, or a bare calendar day (read as
/// midnight UTC).
struct LenientDates {
    private let internet = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter
    private let patterns: [DateFormatter]

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        patterns = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd",
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            return formatter
        }
    }

    func parse(_ value: Any?) -> Date? {
        guard let text = LenientJSON.text(value) else { return nil }
        if let date = internet.date(from: text) ?? fractional.date(from: text) { return date }
        for formatter in patterns {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
