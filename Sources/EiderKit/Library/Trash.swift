import Foundation

enum Trash {
    /// Move to the user's Trash and say where it went.
    @discardableResult
    static func move(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
