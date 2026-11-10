import Foundation
import XCTest
@testable import EiderKit

/// Finding 5: "127.evil.example.com" passed the loopback test because it only
/// looked at a prefix and a dot count.
final class SecurityLoopbackHostTests: XCTestCase {
    private func allowed(_ text: String) -> Bool {
        URL(string: text).map { URLPolicy.isAllowed($0) } ?? false
    }

    func testOnlyRealLoopbackAddressesAreAccepted() {
        for good in ["http://localhost:8080/a", "http://LOCALHOST/a", "http://127.0.0.1/a", "http://127.255.255.254:9/a", "http://127.1.2.3/a", "http://[::1]:9/a"] {
            XCTAssertTrue(allowed(good), good)
        }
        for bad in [
            "http://127.evil.example.com/a", "http://127.0.0.1.example.com/a", "http://127.0.0/a", "http://127.0.0.1.1/a",
            "http://127.0.0.256/a", "http://127.a.b.c/a", "http://128.0.0.1/a", "http://localhost.example.com/a",
            "http://0x7f.0.0.1/a", "http://2130706433/a", "http://[::2]/a", "http://10.0.0.1/a",
        ] {
            XCTAssertFalse(allowed(bad), bad)
        }
    }
}
