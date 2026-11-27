import Foundation

/// The parts of an HTTP/1.1 request the loopback server looks at.
struct HTTPRequest: Equatable {
    let method: String
    /// The path without any query string.
    let path: String
    /// Header names lowercased.
    let headers: [String: String]

    /// Parses the head of a request: the bytes up to, not including, the blank line.
    static func parse(head: Data) -> HTTPRequest? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(requestLine[1])
        guard target.hasPrefix("/") else { return nil }
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequest(method: String(requestLine[0]), path: path, headers: headers)
    }
}

/// How a request's Range header applies to a resource of `size` bytes (RFC 9110, section 14).
enum ByteRange: Equatable {
    case full
    case partial(ClosedRange<Int64>)
    case unsatisfiable

    /// Only a single `bytes=` range is honoured. Multiple ranges or a malformed header fall back
    /// to the whole resource, which RFC 9110 allows a server to do.
    static func evaluate(_ header: String?, size: Int64) -> ByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.hasPrefix("bytes=") else {
            return .full
        }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .full }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        if first.isEmpty {
            // Suffix range: the final N bytes.
            guard let length = Int64(last), length >= 0 else { return .full }
            guard length > 0, size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - length)...(size - 1))
        }
        guard let start = Int64(first), start >= 0 else { return .full }
        guard start < size else { return .unsatisfiable }
        if last.isEmpty { return .partial(start...(size - 1)) }
        guard let end = Int64(last), end >= start else { return .full }
        return .partial(start...min(end, size - 1))
    }
}

/// Byte intervals of a file that have been sent, merged, to tell when every byte went out at
/// least once whether iOS fetched it in one GET or in ranges.
struct ServedRanges: Equatable {
    /// Disjoint, sorted, half-open intervals.
    private(set) var intervals: [Range<Int64>] = []

    var total: Int64 { intervals.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var merged = range
        var kept: [Range<Int64>] = []
        for interval in intervals {
            if interval.upperBound < merged.lowerBound || interval.lowerBound > merged.upperBound {
                kept.append(interval)
            } else {
                merged = min(interval.lowerBound, merged.lowerBound)..<max(interval.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        intervals = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    func covers(size: Int64) -> Bool {
        size == 0 || intervals.first == 0..<size
    }
}
