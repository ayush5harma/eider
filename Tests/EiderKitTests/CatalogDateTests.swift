import Foundation
import XCTest
@testable import EiderCore
@testable import EiderKit

/// The hand-written date reader must give the formatters' answer wherever it
/// answers at all, and leave everything else to them.
final class CatalogDateTests: XCTestCase {
    private let reference = LenientDates()

    private func assertSameAsFormatters(_ text: String, line: UInt = #line) {
        let fast = InternetDate.parse(text)
        XCTAssertNotNil(fast, "fast path should take \(text)", line: line)
        let formatters = reference.parseWithFormattersOnly(text)
        XCTAssertNotNil(formatters, "the formatters read \(text)", line: line)
        XCTAssertEqual(fast?.timeIntervalSinceReferenceDate, formatters?.timeIntervalSinceReferenceDate, text, line: line)
    }

    func testBareDaysMatchTheFormattersAcrossCalendarEdges() {
        let days = [
            "1600-01-01", "1600-02-29", "1700-02-28", "1752-09-14", "1899-12-31", "1900-02-28", "1900-03-01",
            "1969-12-31", "1970-01-01", "1970-01-02", "1999-12-31", "2000-01-01", "2000-02-29", "2004-02-29",
            "2023-12-31", "2024-01-01", "2024-02-29", "2025-12-31", "2026-11-26", "2100-02-28", "2400-02-29",
            "2999-12-31", "9999-12-31",
        ]
        for day in days { assertSameAsFormatters(day) }
    }

    func testEveryDayOfALeapAndACommonYearMatches() {
        for year in [1960, 2024, 2025] {
            var components = DateComponents(year: year, month: 1, day: 1)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            var date = calendar.date(from: components)!
            while calendar.component(.year, from: date) == year {
                components = calendar.dateComponents([.year, .month, .day], from: date)
                assertSameAsFormatters(String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!))
                date = calendar.date(byAdding: .day, value: 1, to: date)!
            }
        }
    }

    func testTimestampsMatchTheFormatters() {
        let stamps = [
            "2024-06-01T12:00:00Z", "1969-12-31T23:59:59Z", "1970-01-01T00:00:00Z", "2000-02-29T23:59:59Z",
            "2024-01-01T00:00:00+05:30", "2023-12-31T18:30:00-08:00", "2024-12-31T23:59:59+14:00",
            "2024-12-31T23:59:59-12:00", "2024-03-10T02:30:00+00:00", "2024-03-10T02:30:00-00:00",
            "1601-07-04T08:15:00Z", "9999-12-31T23:59:59Z",
            "2024-06-01T12:00:00.000Z", "2024-06-01T12:00:00.123Z", "2024-06-01T12:00:00.999Z",
            "1969-12-31T23:59:59.001Z", "1950-05-05T05:05:05.555+02:00", "2024-02-29T00:00:00.500-03:30",
            "2038-01-19T03:14:07.777Z", "2106-02-07T06:28:15.321+01:00",
        ]
        for stamp in stamps { assertSameAsFormatters(stamp) }
    }

    func testManyMillisecondValuesRoundToTheSameDouble() {
        // The fraction is where a different order of operations would show up as a
        // one-ulp difference; every millisecond of one second, at three epochs.
        for prefix in ["1965-03-03T03:03:03", "2024-06-01T12:00:00", "2290-11-11T11:11:11"] {
            for millis in 0..<1000 {
                assertSameAsFormatters(String(format: "%@.%03dZ", prefix, millis))
            }
        }
    }

    func testMalformedAndOddShapesAreLeftToTheFormatters() {
        let odd = [
            "2025-13-01", "2025-00-10", "2025-02-30", "2025-04-31", "2023-02-29", "2025-1-01", "2025-01-1",
            "2025-01-01x", " 2025-01-01", "2025-01-01 ", "2025/01/01", "20250101", "1582-10-04", "1599-12-31",
            "0000-01-01", "2024-06-01T24:00:00Z", "2024-06-01T23:60:00Z", "2024-06-01T23:59:60Z",
            "2024-06-01T12:00:00", "2024-06-01T12:00:00.123", "2024-06-01 12:00:00", "2024-06-01T12:00:00z",
            "2024-06-01t12:00:00Z", "2024-06-01T12:00:00+0530", "2024-06-01T12:00:00+15:00",
            "2024-06-01T12:00:00+05:60", "2024-06-01T12:00:00.12Z", "2024-06-01T12:00:00.1234Z",
            "2024-06-01T12:00:00ZZ", "2024-06-01T12:00Z", "２０２４-06-01", "2024-06-01T12:00:00Z\u{0}",
        ]
        for text in odd {
            XCTAssertNil(InternetDate.parse(text), "fast path must not take \(text)")
            let dates = LenientDates()
            XCTAssertEqual(dates.parse(text), reference.parseWithFormattersOnly(text), "\(text) reads as it did before")
        }
    }

    func testRandomDateShapedTextNeverDisagreesWithTheFormatters() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("0123456789-:T.Z+ ")
        for _ in 0..<3000 {
            let base = Array("2024-06-01T12:00:00.123+05:30".prefix([10, 19, 20, 23, 24, 29].randomElement(using: &generator)!))
            var mutated = base
            for _ in 0..<Int.random(in: 0...2, using: &generator) where !mutated.isEmpty {
                mutated[Int.random(in: 0..<mutated.count, using: &generator)] = alphabet.randomElement(using: &generator)!
            }
            let text = String(mutated)
            guard let fast = InternetDate.parse(text) else { continue }
            XCTAssertEqual(fast, reference.parseWithFormattersOnly(text), text)
        }
    }

    func testRepeatedOddDatesAreRememberedWithinOneParse() {
        let dates = LenientDates()
        let first = dates.parse("2024-06-01 12:00:00")
        XCTAssertEqual(first, Date.utc(2024, 6, 1, 12))
        XCTAssertEqual(dates.parse("2024-06-01 12:00:00"), first)
        XCTAssertNil(dates.parse("not a date"))
        XCTAssertNil(dates.parse("not a date"), "a miss is remembered as a miss")
    }
}
