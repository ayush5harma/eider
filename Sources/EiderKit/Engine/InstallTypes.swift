import Foundation

/// Where an install is. The CLI prints these and the app draws them.
public enum InstallStep: String, Codable, Sendable, CaseIterable {
    case unpack, validate, neutralise, scan, convert, edit, link, sign, verify, place, done
    /// Something the install carried on past (for example a dylib it could not repoint).
    case warning
}

public struct InstallEvent: Codable, Sendable, Equatable {
    public let step: InstallStep
    public let message: String
    /// 0 to 1 over the whole install.
    public let fraction: Double

    public init(step: InstallStep, message: String, fraction: Double) {
        self.step = step
        self.message = message
        self.fraction = min(max(fraction, 0), 1)
    }
}

/// An install that did not happen. `code` is stable (scripts and the app match
/// on it); `message` is a sentence a person can act on.
public struct InstallFailure: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case notAnIPA, unsafeArchive, tooLarge, extractionFailed
        case badBundle, unsafeName
        case encrypted, noArm64Slice, noMachO, machOEdit
        case missingShim, signingFailed, verificationFailed
        case destinationUnusable, destinationConflict, placementFailed
        case unsupportedOption, invalidOption
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// What the owner can ask of an install. Defaults are the legacy installer's.
public struct InstallOptions: Codable, Sendable, Equatable {
    public var destination: URL
    /// UIDeviceFamily gains 6, so UIKit runs the process in the Mac idiom.
    public var macIdiom: Bool
    public var keychainShim: Bool
    /// Prebuilt `.dylib` files linked into the main executable.
    public var extraDylibs: [URL]
    public var displayName: String?
    public var bundleID: String?
    public var removeExtensions: Bool
    /// Not supported yet: the install fails clearly when this is set.
    public var resetData: Bool
    /// Replace a same-named bundle even when its bundle id differs.
    public var force: Bool
    /// Recorded in the library, nothing more.
    public var sourceURL: URL?
    public var ipaSHA256: String?

    public static let defaultDestination = URL(fileURLWithPath: "/Applications", isDirectory: true)

    public init(
        destination: URL = InstallOptions.defaultDestination,
        macIdiom: Bool = false,
        keychainShim: Bool = true,
        extraDylibs: [URL] = [],
        displayName: String? = nil,
        bundleID: String? = nil,
        removeExtensions: Bool = false,
        resetData: Bool = false,
        force: Bool = false,
        sourceURL: URL? = nil,
        ipaSHA256: String? = nil
    ) {
        self.destination = destination
        self.macIdiom = macIdiom
        self.keychainShim = keychainShim
        self.extraDylibs = extraDylibs
        self.displayName = displayName
        self.bundleID = bundleID
        self.removeExtensions = removeExtensions
        self.resetData = resetData
        self.force = force
        self.sourceURL = sourceURL
        self.ipaSHA256 = ipaSHA256
    }
}
