import CoreGraphics
import Foundation
import ImageIO

/// Turns fetched bytes into a bitmap no larger than the view that shows it.
/// Called off the main actor only: a full-size decode of a 1024-pixel icon for
/// a 36-point row costs 4 MB and milliseconds, a thumbnail a few KB.
enum ImageDecoder {
    /// A small file can still declare a huge canvas (a PNG bomb). Icons are at
    /// most 1024 x 1024 and screenshots a few megapixels; 40 MP leaves room.
    static let maxSourcePixels = 40_000_000

    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    /// True when ImageIO recognises the bytes as an image of an acceptable
    /// size. Reads the header only.
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return false }
        return acceptable(source)
    }

    /// A bitmap whose longer side is at most `maxPixelSize`, decoded now (not
    /// lazily at first draw, which would be on the main thread).
    static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), acceptable(source) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func acceptable(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return false }
        return width.multipliedReportingOverflow(by: height).partialValue <= maxSourcePixels
            && width <= maxSourcePixels && height <= maxSourcePixels
    }
}
