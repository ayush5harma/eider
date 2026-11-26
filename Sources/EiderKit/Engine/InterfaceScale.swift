import CoreGraphics
import Foundation

/// How large an installed app draws on the Mac. An iPad app under Mac Catalyst
/// is shrunk to 77% ("Scale Interface to Match iPad"), so its 44 pt controls
/// and 11 pt labels end up 34 pt and 8.5 pt on screen, smaller than Apple's own
/// apps. UIKit reads two keys from the app's own preferences at launch
/// (`updateGlobalUserInterfaceIdiom` in UIKitCore, macOS 27.3; found in the
/// dyld cache and checked with lldb on YouTube 21.47.6, 2026-11-27):
/// `iOSMacScaleFactor`, a number that replaces the 77% for the whole process,
/// and `UIUserInterfaceIdiomMac`, a boolean that runs it in the Mac idiom
/// (1:1, Mac-style controls) without touching UIDeviceFamily. Eider writes
/// them into the app's container (`AppPreferences`), so a change needs a
/// relaunch, never a reinstall or a new signature.
public enum InterfaceScale: String, Sendable, CaseIterable, Codable {
    /// From the display the setting is applied on (`autoFactor(for:)`).
    case auto
    /// UIKit's own iPad default: both keys removed.
    case ipad = "77"
    case percent85 = "85"
    case percent100 = "100"
    case percent115 = "115"
    /// The Mac idiom at 1:1. Mac-style controls; some iPad layouts break.
    case macIdiom = "mac"

    /// What new installs get (the CLI's `--interface-size` and the app's
    /// install sheet start here). Library entries written before 0.1.9 have
    /// no setting (nil) and keep the 77% until the owner picks one.
    public static let newInstallDefault = InterfaceScale.auto

    /// The fixed factor, nil for `auto` (display-dependent) and `macIdiom`.
    public var fixedFactor: Double? {
        switch self {
        case .ipad: 0.77
        case .percent85: 0.85
        case .percent100: 1.0
        case .percent115: 1.15
        case .auto, .macIdiom: nil
        }
    }

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .ipad: "77% (iPad)"
        case .percent85: "85%"
        case .percent100: "100%"
        case .percent115: "115%"
        case .macIdiom: "Mac idiom"
        }
    }

    /// Reads what a person types: "auto", "77", "77%", "0.77", "ipad",
    /// "100", "1.0", "mac", "mac-idiom" and so on. nil for anything else.
    public init?(argument: String) {
        let text = argument.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "%", with: "")
        switch text {
        case "auto": self = .auto
        case "ipad", "77", "0.77": self = .ipad
        case "85", "0.85": self = .percent85
        case "100", "1", "1.0": self = .percent100
        case "115", "1.15": self = .percent115
        case "mac", "mac-idiom", "macidiom", "mac idiom": self = .macIdiom
        default: return nil
        }
    }

    /// A value this version does not know (written by a newer Eider) reads as
    /// `auto` rather than failing the whole library file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InterfaceScale(rawValue: raw) ?? .auto
    }

    /// The factor UIKit is given on `display`: nil means "remove the key",
    /// which is UIKit's own 77% (for `ipad`) or the Mac idiom's 1:1.
    public func factor(on display: DisplayMetrics?) -> Double? {
        switch self {
        case .ipad, .macIdiom: nil
        case .auto: Self.autoFactor(for: display)
        default: fixedFactor
        }
    }

    // MARK: Auto

    /// Points per inch of a MacBook Pro built-in display at its default
    /// resolution (14.2 in, 3024 px, "looks like" 1512 pt): Apple's reference
    /// for how large a Mac point is meant to look at laptop distance.
    static let referencePointsPerInch = 127.0
    /// Typical eye distance, in cm, to a laptop's built-in display and to a desk display.
    static let builtInDistance = 50.0
    static let externalDistance = 65.0
    static let autoRange = 1.0...1.25

    /// The Auto rule. 100% on the built-in display and on anything Eider cannot
    /// measure: UIKit points then map 1:1 to Mac points, which is how Apple's
    /// own apps draw (Music and TV: 28 pt buttons, 32 pt rows), and macOS already
    /// sizes Mac points from the resolution chosen in Displays settings. An
    /// external display sits further away (about 65 cm against 50), so there the
    /// factor makes one point cover the same visual angle as on a MacBook's
    /// built-in display at its default resolution: points per inch x 65 / (127
    /// x 50). A 27-inch 5K or 4K display at "looks like 2560 x 1440" (109 pt/in)
    /// gets 110%; one set to larger text (fewer points per inch) never drops
    /// below 100%; the result is kept within 100-125% and rounded to 5%.
    public static func autoFactor(for display: DisplayMetrics?) -> Double {
        guard let display, !display.isBuiltIn, let pointsPerInch = display.pointsPerInch else { return 1.0 }
        let visual = pointsPerInch * externalDistance / (referencePointsPerInch * builtInDistance)
        let rounded = (visual * 20).rounded() / 20
        return min(max(rounded, autoRange.lowerBound), autoRange.upperBound)
    }
}

/// The display a scale is worked out for: its size in Mac points, its pixels per
/// point, and its physical width when the display reports one (EDID; virtual
/// displays and some projectors report none).
public struct DisplayMetrics: Sendable, Equatable {
    public var pointWidth: Double
    public var pointHeight: Double
    public var backingScale: Double
    public var physicalWidthMM: Double?
    public var isBuiltIn: Bool

    public init(pointWidth: Double, pointHeight: Double, backingScale: Double, physicalWidthMM: Double?, isBuiltIn: Bool) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.backingScale = backingScale
        self.physicalWidthMM = physicalWidthMM
        self.isBuiltIn = isBuiltIn
    }

    /// Mac points per physical inch; nil without a usable physical size.
    public var pointsPerInch: Double? {
        guard let millimetres = physicalWidthMM, millimetres > 10, pointWidth > 0 else { return nil }
        return pointWidth / (millimetres / 25.4)
    }

    /// The main display (the one with the menu bar), through CoreGraphics so the
    /// CLI needs no AppKit. nil when there is no display session.
    public static func main() -> DisplayMetrics? {
        let display = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return nil }
        let size = CGDisplayScreenSize(display)
        return DisplayMetrics(
            pointWidth: Double(mode.width), pointHeight: Double(mode.height),
            backingScale: Double(mode.pixelWidth) / Double(mode.width),
            physicalWidthMM: size.width > 0 ? Double(size.width) : nil,
            isBuiltIn: CGDisplayIsBuiltin(display) != 0)
    }

    public var summary: String {
        let size = "\(Int(pointWidth)) x \(Int(pointHeight)) pt at \(backingScale.formatted(.number.precision(.fractionLength(0...2))))x"
        let density = pointsPerInch.map { ", \(Int($0.rounded())) pt/in" } ?? ""
        return "\(isBuiltIn ? "built-in" : "external") display, \(size)\(density)"
    }
}
