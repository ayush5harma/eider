import Foundation

/// The date shapes real sources overwhelmingly use, read by hand. A 17,430-app
/// source (fastsign.dev, 2026-11-26) writes all 34,860 of its dates as bare days,
/// the last of the formatters `LenientDates` tries: 65% of `eider source add`
/// went to the seven failed ICU attempts before the one that matched.
///
/// Only exact shapes are taken; anything else returns nil and goes to the
/// formatters, so an odd date reads exactly as it did before:
/// - `yyyy-MM-dd` (midnight UTC)
/// - `yyyy-MM-ddTHH:mm:ss` then `Z` or `+hh:mm` / `-hh:mm`
/// - the same with `.SSS` (exactly three digits) after the seconds
///
/// Years before 1600 are left to the formatters, whose calendar switches to
/// Julian before 1582; seconds of 60, hour 24 and impossible days are left to them too.
enum InternetDate {
    private static let shortest = 10
    private static let longest = 29
    private static let unixToReference: Double = 978_307_200

    static func parse(_ text: String) -> Date? {
        let count = text.utf8.count
        guard count == shortest || (count >= 20 && count <= longest) else { return nil }
        return parse(Array(text.utf8))
    }

    private static func parse(_ bytes: [UInt8]) -> Date? {
        guard let year = number(bytes, 0, 4), bytes[4] == ascii("-"),
              let month = number(bytes, 5, 2), bytes[7] == ascii("-"),
              let day = number(bytes, 8, 2),
              (1600...9999).contains(year), (1...12).contains(month), (1...days(inMonth: month, year: year)).contains(day)
        else { return nil }
        let midnight = daysFromCivil(year: year, month: month, day: day) * 86_400
        if bytes.count == shortest { return Date(timeIntervalSince1970: Double(midnight)) }

        guard bytes[10] == ascii("T"),
              let hour = number(bytes, 11, 2), bytes[13] == ascii(":"),
              let minute = number(bytes, 14, 2), bytes[16] == ascii(":"),
              let second = number(bytes, 17, 2),
              hour < 24, minute < 60, second < 60
        else { return nil }

        var index = 19
        var millis: Int?
        if bytes[index] == ascii(".") {
            guard let value = number(bytes, index + 1, 3) else { return nil }
            millis = value
            index += 4
        }
        guard let offset = zoneOffset(bytes, from: index) else { return nil }
        let seconds = midnight + hour * 3600 + minute * 60 + second - offset
        guard let millis else { return Date(timeIntervalSince1970: Double(seconds)) }
        // The formatter goes through ICU's milliseconds since 1970 and then subtracts
        // the 2001 offset; the same two steps give the same double.
        return Date(timeIntervalSinceReferenceDate: Double(seconds * 1000 + millis) / 1000 - unixToReference)
    }

    /// `Z`, or a sign, two hour digits, a colon and two minute digits, ending the text.
    private static func zoneOffset(_ bytes: [UInt8], from index: Int) -> Int? {
        let rest = bytes.count - index
        if rest == 1, bytes[index] == ascii("Z") { return 0 }
        guard rest == 6, bytes[index] == ascii("+") || bytes[index] == ascii("-"),
              let hours = number(bytes, index + 1, 2), bytes[index + 3] == ascii(":"),
              let minutes = number(bytes, index + 4, 2),
              hours <= 14, minutes < 60
        else { return nil }
        let magnitude = hours * 3600 + minutes * 60
        return bytes[index] == ascii("-") ? -magnitude : magnitude
    }

    private static func number(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Int? {
        guard start + length <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[start..<(start + length)] {
            guard byte >= ascii("0"), byte <= ascii("9") else { return nil }
            value = value * 10 + Int(byte - ascii("0"))
        }
        return value
    }

    private static func ascii(_ character: Unicode.Scalar) -> UInt8 { UInt8(character.value) }

    private static func days(inMonth month: Int, year: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's
    /// `days_from_civil`).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
