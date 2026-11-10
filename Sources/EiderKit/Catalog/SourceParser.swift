import Foundation

public enum SourceParser {
    /// Detects the format and returns the vetted catalog. `url` is where the
    /// bytes came from: relative addresses resolve against it, and a file URL
    /// there is what lets the document point at local files.
    public static func parse(data: Data, from url: URL, now: Date = Date()) throws -> CatalogSource {
        let root = try LenientJSON.object(from: data)
        var context = ParseContext(sourceURL: url)

        if let list = root as? [Any] {
            return try PlayCoverParser.parse(list: list, wrapper: [:], context: &context, now: now)
        }
        guard let object = root as? JSONDict else { throw CatalogFailure.unrecognizedFormat }
        if object["apps"] is [Any] {
            return try AltStoreParser.parse(root: object, context: &context, now: now)
        }
        if let list = object["data"] as? [Any] {
            return try PlayCoverParser.parse(list: list, wrapper: object, context: &context, now: now)
        }
        throw CatalogFailure.unrecognizedFormat
    }
}
