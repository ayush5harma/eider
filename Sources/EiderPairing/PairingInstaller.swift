import Foundation
import IDeviceFFI

/// Whether the iPhone's installation service can be reached with this pairing file.
public enum PairingReachability: Sendable, Equatable {
    /// Pairing verified, tunnel up, RSD offers AFC and installation_proxy.
    case ready
    /// No connection: LocalDevVPN is off, or the address is wrong. The text says what failed.
    case unreachable(String)
    /// The iPhone answered but refused: the pairing file is wrong or was revoked, or the
    /// tunnel or its services did not come up. `PairingInstaller.verify()` throws the typed
    /// error when the UI has to tell these apart.
    case refused(String)
}

public enum PairingInstallProgress: Sendable, Equatable {
    case connecting
    /// Bytes of the IPA sent to the iPhone's staging folder.
    case uploading(sent: Int64, total: Int64)
    /// installation_proxy's own percent complete.
    case installing(percent: Int)
    case finished
}

public enum PairingInstallError: Error, LocalizedError, Sendable, Equatable {
    case invalidPairingFile(String)
    /// No connection to the pairing service (LocalDevVPN off, or a wrong address).
    case unreachable(String)
    /// The iPhone did not accept the pairing file.
    case pairingRejected(String)
    /// Paired, but the tunnel, RSD or a service did not answer.
    case serviceUnavailable(String)
    /// The iPhone answered, then stopped answering before the step finished.
    case timedOut(String)
    /// A bad argument from the caller (a bundle id with a slash, a host that is not an IP).
    case invalidArgument(String)
    case ipaUnreadable(String)
    case uploadFailed(String)
    case installFailed(String)
    case uninstallFailed(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPairingFile(let detail):
            return detail
        case .unreachable(let detail):
            return "Can't reach this iPhone's installer. Turn on LocalDevVPN and try again. (\(detail))"
        case .pairingRejected(let detail):
            return "This iPhone did not accept the pairing file. Make a new RemotePairing "
                + "pairing file on your computer and import it. (\(detail))"
        case .serviceUnavailable(let detail):
            return "The iPhone's installation service did not answer. Toggle LocalDevVPN off "
                + "and on, then try again. (\(detail))"
        case .timedOut(let detail):
            return "The iPhone stopped answering. Keep it awake with LocalDevVPN on, then try "
                + "again. (\(detail))"
        case .invalidArgument(let detail):
            return "Eider passed the installer something it cannot use. (\(detail))"
        case .ipaUnreadable(let detail):
            return "Eider could not read the IPA. (\(detail))"
        case .uploadFailed(let detail):
            return "Copying the IPA to the iPhone failed. (\(detail))"
        case .installFailed(let detail):
            return "iOS refused to install the app. (\(detail))"
        case .uninstallFailed(let detail):
            return "iOS refused to remove the app. (\(detail))"
        case .internalError(let detail):
            return "Pairing install failed. (\(detail))"
        }
    }
}

/// Installs IPAs on an iPhone through its own installation service, reached over
/// RemotePairing: pair-verify with an RP pairing file, a TLS-PSK tunnel, RSD, an AFC upload
/// to PublicStaging and installation_proxy Install. No manifest server is involved.
///
/// On the iPhone itself the service is reached through LocalDevVPN's loopback tunnel at
/// 10.7.0.1:49152. From a Mac it is the phone's Wi-Fi address and the same port: measured on
/// 2026-11-28 to an iPhone 17 Pro on iOS 27.3 at 192.168.1.50:49152, where RSD offered 85
/// services and a 21 KB probe IPA installed and uninstalled.
///
/// The pairing is only ever verified, never set up: a rejected pairing file is an error, not
/// a Trust prompt on the phone. Each call opens and closes its own tunnel and cannot be
/// cancelled once started; every step has an upper bound in the library (see
/// eider_idevice.h), so a phone that stops answering ends the call with `.timedOut`. Installs
/// and uninstalls run one at a time; check() runs on its own queue so a status row never
/// waits behind an install.
public actor PairingInstaller {
    private let pairingFile: RemotePairingFile
    private let host: String
    private let port: UInt16
    private let operationQueue = DispatchQueue(label: "io.github.ayush5harma.EiderPairing.operation")
    private let checkQueue = DispatchQueue(label: "io.github.ayush5harma.EiderPairing.check")

    /// check() is meant for a status row; the tunnel was up in 0.32 to 0.44 s on 2026-11-28.
    static let checkTimeoutMilliseconds: UInt32 = 5_000
    /// Bounds the TCP connect, and separately pairing, tunnel and RSD, for install and uninstall.
    static let connectTimeoutMilliseconds: UInt32 = 15_000

    public init(pairingFile: RemotePairingFile, host: String = "10.7.0.1", port: UInt16 = 49152) {
        self.pairingFile = pairingFile
        self.host = host
        self.port = port
    }

    /// Connects, verifies the pairing, opens the tunnel and does the RSD handshake.
    public func check() async -> PairingReachability {
        switch await verifyResult() {
        case .success:
            return .ready
        case .failure(.unreachable(let detail)), .failure(.timedOut(let detail)):
            return .unreachable(detail)
        case .failure(let error):
            return .refused(error.detail)
        }
    }

    /// The same as check(), but throws the typed error, for a UI that must tell a rejected
    /// pairing file (re-import it) from a tunnel that did not come up (retry, toggle the VPN).
    public func verify() async throws {
        try await verifyResult().get()
    }

    private func verifyResult() async -> Result<Void, PairingInstallError> {
        let (host, port, pairing) = (host, port, pairingFile.data)
        return await run(on: checkQueue) {
            Self.call { message in
                pairing.withUnsafeBytes { bytes in
                    eider_idevice_check(host, port, bytes.bindMemory(to: UInt8.self).baseAddress,
                                        bytes.count, Self.checkTimeoutMilliseconds, message)
                }
            }
        }
    }

    public func install(
        ipa: URL,
        bundleID: String,
        progress: @escaping @Sendable (PairingInstallProgress) -> Void
    ) async throws {
        guard ipa.isFileURL, FileManager.default.isReadableFile(atPath: ipa.path) else {
            throw PairingInstallError.ipaUnreadable("\(ipa.lastPathComponent) is not a readable file")
        }
        try Self.validate(bundleID: bundleID)
        let (host, port, pairing) = (host, port, pairingFile.data)
        let box = Unmanaged.passRetained(ProgressBox(progress))
        defer { box.release() }
        let context = UInt(bitPattern: box.toOpaque())
        try await run(on: operationQueue) {
            Self.call { message in
                pairing.withUnsafeBytes { bytes in
                    eider_idevice_install(host, port, bytes.bindMemory(to: UInt8.self).baseAddress,
                                          bytes.count, Self.connectTimeoutMilliseconds,
                                          ipa.path, bundleID, progressTrampoline,
                                          UnsafeMutableRawPointer(bitPattern: context), message)
                }
            }
        }.get()
    }

    public func uninstall(bundleID: String) async throws {
        try Self.validate(bundleID: bundleID)
        let (host, port, pairing) = (host, port, pairingFile.data)
        try await run(on: operationQueue) {
            Self.call { message in
                pairing.withUnsafeBytes { bytes in
                    eider_idevice_uninstall(host, port, bytes.bindMemory(to: UInt8.self).baseAddress,
                                            bytes.count, Self.connectTimeoutMilliseconds,
                                            bundleID, message)
                }
            }
        }.get()
    }

    // MARK: - Bridge

    /// Runs a blocking C call on a private queue, off Swift's cooperative threads.
    private func run(
        on queue: DispatchQueue,
        _ body: @escaping @Sendable () -> Result<Void, PairingInstallError>
    ) async -> Result<Void, PairingInstallError> {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private static func call(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) -> Result<Void, PairingInstallError> {
        var message: UnsafeMutablePointer<CChar>?
        let code = body(&message)
        let detail = message.map { String(cString: $0) } ?? "code \(code)"
        if let message { eider_idevice_free_string(message) }
        guard code != Int32(EIDER_IDEVICE_OK) else { return .success(()) }
        return .failure(error(code: code, detail: detail))
    }

    static func error(code: Int32, detail: String) -> PairingInstallError {
        switch Int(code) {
        case Int(EIDER_IDEVICE_ERR_PAIRING_FILE):
            return .invalidPairingFile("The pairing file is not a RemotePairing pairing file: \(detail)")
        case Int(EIDER_IDEVICE_ERR_UNREACHABLE):
            return .unreachable(detail)
        case Int(EIDER_IDEVICE_ERR_TIMEOUT):
            return .timedOut(detail)
        case Int(EIDER_IDEVICE_ERR_INVALID_ARGUMENT):
            return .invalidArgument(detail)
        case Int(EIDER_IDEVICE_ERR_PAIRING_REJECTED):
            return .pairingRejected(detail)
        case Int(EIDER_IDEVICE_ERR_TUNNEL), Int(EIDER_IDEVICE_ERR_SERVICE):
            return .serviceUnavailable(detail)
        case Int(EIDER_IDEVICE_ERR_LOCAL_FILE):
            return .ipaUnreadable(detail)
        case Int(EIDER_IDEVICE_ERR_UPLOAD):
            return .uploadFailed(detail)
        case Int(EIDER_IDEVICE_ERR_INSTALL):
            return .installFailed(detail)
        case Int(EIDER_IDEVICE_ERR_UNINSTALL):
            return .uninstallFailed(detail)
        default:
            return .internalError(detail)
        }
    }

    /// The bundle id names the staging file (PublicStaging/<id>.ipa), so it may not carry a
    /// path separator.
    private static func validate(bundleID: String) throws {
        guard !bundleID.isEmpty, !bundleID.contains("/"), !bundleID.contains("\0") else {
            throw PairingInstallError.invalidArgument("\"\(bundleID)\" is not a bundle id")
        }
    }
}

extension PairingInstallError {
    /// The detail text without the user-facing preamble.
    var detail: String {
        switch self {
        case .invalidPairingFile(let d), .unreachable(let d), .pairingRejected(let d),
             .serviceUnavailable(let d), .timedOut(let d), .invalidArgument(let d),
             .ipaUnreadable(let d), .uploadFailed(let d),
             .installFailed(let d), .uninstallFailed(let d), .internalError(let d):
            return d
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    let handler: @Sendable (PairingInstallProgress) -> Void
    init(_ handler: @escaping @Sendable (PairingInstallProgress) -> Void) { self.handler = handler }
}

/// Called by the C side on its operation thread while eider_idevice_install blocks.
private let progressTrampoline: @convention(c) (UnsafeMutableRawPointer?, Int32, Int64, Int64) -> Void = {
    context, phase, done, total in
    guard let context else { return }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    switch Int(phase) {
    case Int(EIDER_IDEVICE_PHASE_CONNECTING):
        box.handler(.connecting)
    case Int(EIDER_IDEVICE_PHASE_UPLOADING):
        box.handler(.uploading(sent: done, total: total))
    case Int(EIDER_IDEVICE_PHASE_INSTALLING):
        box.handler(.installing(percent: Int(done)))
    case Int(EIDER_IDEVICE_PHASE_FINISHED):
        box.handler(.finished)
    default:
        break
    }
}
