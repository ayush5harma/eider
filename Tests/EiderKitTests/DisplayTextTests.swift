import Foundation
import XCTest
@testable import EiderCore
@testable import EiderKit

/// The printable-ASCII shortcut in `DisplayText` must give exactly what the
/// general scalar filter and Foundation trim gave.
final class DisplayTextTests: XCTestCase {
    private func referenceName(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !DisplayText.isUnsafe($0) }))
            .trimmingCharacters(in: .whitespaces)
    }

    private func referenceProse(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !DisplayText.isUnsafe($0) || $0 == "\n" || $0 == "\t" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertMatches(_ text: String, line: UInt = #line) {
        XCTAssertEqual(DisplayText.sanitized(text), referenceName(text), text.debugDescription, line: line)
        XCTAssertEqual(DisplayText.sanitizedProse(text), referenceProse(text), text.debugDescription, line: line)
    }

    func testHandPickedTextMatchesTheGeneralPath() {
        let samples = [
            "", " ", "   ", "\t", "\n", "\t\n ", "App", " App ", "  App", "App  ", "My App 2.0", "a",
            "line one\nline two", "\nleading and trailing\n", "\ttabbed\t", "tab\tinside", "crlf\r\nline",
            "bell\u{7}", "del\u{7F}", "esc\u{1B}[31mred", "nul\u{0}x", "caf\u{E9}", " caf\u{E9} ", "\u{202E}evil",
            "zero\u{200B}width", "\u{00A0}nbsp\u{00A0}", "\u{3000}ideographic\u{3000}", "emoji \u{1F600} ",
            "~!@#$%^&*()_+{}|:\"<>?`-=[]\\;',./", "\u{85}next line", "\u{2028}sep",
        ]
        for sample in samples { assertMatches(sample) }
    }

    func testRandomTextMatchesTheGeneralPath() {
        var generator = SystemRandomNumberGenerator()
        let pool: [Unicode.Scalar] = ["a", "Z", "0", " ", " ", "\t", "\n", "\r", "\u{0}", "\u{7F}", "\u{1B}", "~", "\u{A0}", "\u{E9}", "\u{200B}", "\u{202E}"]
        for _ in 0..<5000 {
            var scalars = String.UnicodeScalarView()
            for _ in 0..<Int.random(in: 0...12, using: &generator) { scalars.append(pool.randomElement(using: &generator)!) }
            assertMatches(String(scalars))
        }
    }

    func testFieldTrimMatchesFoundation() {
        for sample in ["x", " x", "x ", "\nx", "x\t", "\u{A0}x", "x\u{3000}", "a b", "   ", "\u{E9}", "\u{E9} "] {
            let expected = sample.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(LenientJSON.text(sample), expected.isEmpty ? nil : expected, sample.debugDescription)
        }
    }
}
