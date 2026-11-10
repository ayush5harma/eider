import Foundation

/// Moves one URL into a `.part` file, resuming where the file left off when the
/// server honours a Range request and starting over when it does not.
struct PartTransfer {
    let transfer: HTTPTransfer
    let maxBytes: Int64
    let emit: @Sendable (DownloadEvent) -> Void

    private enum Outcome {
        case complete
        case restart
    }

    private enum Start {
        case fresh(total: Int64?)
        case resume(total: Int64?)
        case restart
    }

    private static let progressInterval: TimeInterval = 0.1

    /// Returns once `part` holds the complete body. A transfer that is cancelled
    /// throws CancellationError and leaves the `.part` for the next run.
    ///
    /// A `.part` is resumed only with the validator (ETag or Last-Modified) its first
    /// response carried, sent as `If-Range`: a server whose file changed answers 200
    /// with the new bytes instead of 206, so old and new content are never joined.
    /// A part with no validator is started over.
    func run(url: URL, part: URL) async throws {
        var offset = fileSize(part)
        var validator = Self.savedValidator(for: part)
        if offset > 0, validator == nil { Self.discard(part); offset = 0 }
        for _ in 0..<2 {
            if try await attempt(url: url, part: part, offset: offset, validator: validator) == .complete { return }
            Self.discard(part)
            (offset, validator) = (0, nil)
        }
        throw DownloadFailure.network("the server would not start a fresh download")
    }

    // MARK: Validator

    private static func validatorFile(for part: URL) -> URL { part.appendingPathExtension("validator") }

    static func savedValidator(for part: URL) -> String? {
        guard let text = try? String(contentsOf: validatorFile(for: part), encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func discard(_ part: URL, keepingPart: Bool = false) {
        if !keepingPart { try? FileManager.default.removeItem(at: part) }
        try? FileManager.default.removeItem(at: validatorFile(for: part))
    }

    /// A strong ETag, else Last-Modified. A weak ETag cannot be used in If-Range.
    static func validator(of response: HTTPURLResponse) -> String? {
        if let tag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespaces),
           tag.hasPrefix("\""), tag.count >= 2 { return tag }
        let modified = response.value(forHTTPHeaderField: "Last-Modified")?.trimmingCharacters(in: .whitespaces)
        return modified?.isEmpty == false ? modified : nil
    }

    private func saveValidator(of response: HTTPURLResponse, for part: URL) {
        guard let value = Self.validator(of: response) else {
            try? FileManager.default.removeItem(at: Self.validatorFile(for: part))
            return
        }
        try? Data(value.utf8).write(to: Self.validatorFile(for: part), options: .atomic)
    }

    private func attempt(url: URL, part: URL, offset: Int64, validator: String?) async throws -> Outcome {
        var request = URLRequest(url: url)
        // Identity encoding keeps Content-Length and Range in terms of file bytes.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0, let validator {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }

        var handle: FileHandle?
        defer { try? handle?.close() }
        var received = offset
        var expected: Int64?
        var lastEmitted: Int64 = -1
        var lastEmitTime = Date.distantPast

        for try await event in transfer.events(for: request) {
            switch event {
            case .response(let response):
                switch try classify(response, offset: offset) {
                case .restart:
                    return .restart
                case .fresh(let total):
                    (received, expected) = (0, total)
                    saveValidator(of: response, for: part)
                case .resume(let total):
                    expected = total
                }
                try rejectOversize(expected, part: part)
                handle = try open(part, keepingFirst: received)
                emit(.started(expectedBytes: expected))
            case .data(let chunk):
                guard let handle else { throw DownloadFailure.network("data arrived before the response") }
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                if received > maxBytes {
                    Self.discard(part)
                    throw DownloadFailure.sizeCapExceeded(limit: maxBytes)
                }
                if Date().timeIntervalSince(lastEmitTime) >= Self.progressInterval {
                    emit(.progress(received: received, expected: expected))
                    (lastEmitted, lastEmitTime) = (received, Date())
                }
            }
        }
        // A cancelled consumer ends the loop quietly; it must not look like success.
        try Task.checkCancellation()
        guard handle != nil else { throw DownloadFailure.network("the server sent no response") }
        if lastEmitted != received { emit(.progress(received: received, expected: expected)) }
        if let expected, received != expected {
            throw DownloadFailure.incomplete(received: received, expected: expected)
        }
        return .complete
    }

    private func classify(_ response: HTTPURLResponse, offset: Int64) throws -> Start {
        let length: Int64? = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        switch response.statusCode {
        case 206 where offset > 0:
            guard let range = Self.contentRange(response), range.start == offset else { return .restart }
            return .resume(total: range.total ?? length.map { offset + $0 })
        case 200:
            return .fresh(total: length)
        case 416 where offset > 0:
            return .restart
        default:
            throw DownloadFailure.httpStatus(response.statusCode)
        }
    }

    /// `Content-Range: bytes 1200-2999/3000`; the total may be `*`.
    private static func contentRange(_ response: HTTPURLResponse) -> (start: Int64, total: Int64?)? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              header.lowercased().hasPrefix("bytes ")
        else { return nil }
        let spec = header.dropFirst("bytes ".count).split(separator: "/", omittingEmptySubsequences: false)
        guard spec.count == 2, let start = spec[0].split(separator: "-").first.flatMap({ Int64($0) }) else {
            return nil
        }
        return (start, Int64(spec[1]))
    }

    private func rejectOversize(_ expected: Int64?, part: URL) throws {
        guard let expected, expected > maxBytes else { return }
        Self.discard(part)
        throw DownloadFailure.sizeCapExceeded(limit: maxBytes)
    }

    /// Opens `part` positioned after its first `kept` bytes, dropping anything beyond.
    private func open(_ part: URL, keepingFirst kept: Int64) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: part.path) {
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
                throw DownloadFailure.disk("cannot create \(part.lastPathComponent)")
            }
        }
        let handle = try FileHandle(forWritingTo: part)
        try handle.truncate(atOffset: UInt64(kept))
        try handle.seek(toOffset: UInt64(kept))
        return handle
    }

    private func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }
}
