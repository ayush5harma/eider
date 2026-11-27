import Foundation
import XCTest
@testable import EiderInstall

final class HTTPTests: XCTestCase {
    func testParsesRequestHead() {
        let head = Data("GET /abc/app.ipa?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-9\r\n".utf8)
        let request = HTTPRequest.parse(head: head)
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/abc/app.ipa")
        XCTAssertEqual(request?.headers["range"], "bytes=0-9")
        XCTAssertEqual(request?.headers["host"], "127.0.0.1")
    }

    func testRejectsMalformedHeads() {
        XCTAssertNil(HTTPRequest.parse(head: Data("GET\r\n".utf8)))
        XCTAssertNil(HTTPRequest.parse(head: Data("GET http://x/ HTTP/1.1\r\n".utf8)))
        XCTAssertNil(HTTPRequest.parse(head: Data("GET / SPDY/3\r\n".utf8)))
        XCTAssertNil(HTTPRequest.parse(head: Data("GET / HTTP/1.1\r\nno-colon\r\n".utf8)))
    }

    func testByteRanges() {
        XCTAssertEqual(ByteRange.evaluate(nil, size: 100), .full)
        XCTAssertEqual(ByteRange.evaluate("bytes=0-9", size: 100), .partial(0...9))
        XCTAssertEqual(ByteRange.evaluate("bytes=90-", size: 100), .partial(90...99))
        XCTAssertEqual(ByteRange.evaluate("bytes=90-500", size: 100), .partial(90...99))
        XCTAssertEqual(ByteRange.evaluate("bytes=-10", size: 100), .partial(90...99))
        XCTAssertEqual(ByteRange.evaluate("bytes=-500", size: 100), .partial(0...99))
        XCTAssertEqual(ByteRange.evaluate("bytes=100-", size: 100), .unsatisfiable)
        XCTAssertEqual(ByteRange.evaluate("bytes=-0", size: 100), .unsatisfiable)
        XCTAssertEqual(ByteRange.evaluate("bytes=0-1,5-6", size: 100), .full)
        XCTAssertEqual(ByteRange.evaluate("bytes=9-1", size: 100), .full)
        XCTAssertEqual(ByteRange.evaluate("items=0-1", size: 100), .full)
    }

    func testServedRangesMergeToFullCoverage() {
        var served = ServedRanges()
        served.insert(50..<100)
        XCTAssertFalse(served.covers(size: 100))
        served.insert(0..<20)
        served.insert(10..<50)
        XCTAssertEqual(served.intervals, [0..<100])
        XCTAssertEqual(served.total, 100)
        XCTAssertTrue(served.covers(size: 100))
        served.insert(0..<100)
        XCTAssertEqual(served.total, 100)
    }
}
