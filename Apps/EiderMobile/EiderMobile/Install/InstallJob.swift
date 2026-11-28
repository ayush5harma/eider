import EiderCore
import Foundation
import Observation

/// One install of one IPA: Unpack, Sign, Package, Install, each step's state
/// shown by the Install sheet (or the Updates row for Update All). The device
/// work is behind `SigningService` and `DeviceInstaller`; this only orders it,
/// keeps a work directory for it and records the result.
@MainActor @Observable
final class InstallJob: Identifiable {
    enum Step: String, CaseIterable, Identifiable, Sendable {
        case unpack = "Unpack"
        case sign = "Sign"
        case package = "Package"
        case install = "Install"

        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case waiting
        case running
        case done
        case failed(String)
    }

    struct Request: Sendable {
        let ipa: LibraryIPA
        let ipaURL: URL
        let certificate: CertificateRecord
        let options: SignOptions
    }

    /// How long the work directory outlives the hand-off: EiderInstall keeps
    /// serving for a 10 s grace period in case iOS asks for a range again.
    private static let cleanupDelay: Duration = .seconds(60)

    let id = UUID()
    private(set) var phases: [Step: Phase] = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .waiting) })
    private(set) var isRunning = false
    /// What the Install step is waiting on ("Waiting for you to confirm...").
    private(set) var installDetail: String?
    /// iOS's fetch of the signed IPA, once it has started.
    private(set) var installFraction: Double?
    /// What the progress bar's spoken label says it is measuring.
    private(set) var installProgressLabel = "Installing"
    private(set) var installed: InstalledApp?
    private(set) var failure: String?

    func phase(of step: Step) -> Phase { phases[step] ?? .waiting }

    /// Runs every step in order and stops at the first failure. Returns the
    /// record kept once iOS has the whole signed IPA.
    @discardableResult
    func run(_ request: Request, model: MobileModel) async -> InstalledApp? {
        guard !isRunning else { return nil }
        isRunning = true
        failure = nil
        installed = nil
        installDetail = nil
        installFraction = nil
        installProgressLabel = "Installing"
        phases = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .waiting) })
        defer { isRunning = false }

        let signer = model.signer
        let installer = model.installer
        let work = model.paths.work.appendingPathComponent(id.uuidString, isDirectory: true)
        defer { Self.removeLater(work) }

        do {
            let material = try await model.certificateStore.material(for: request.certificate.id)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let appURL = try await step(.unpack) {
                try await installer.unpack(ipaAt: request.ipaURL, into: work.appendingPathComponent("unpacked", isDirectory: true))
            }
            let info = try await Task.detached { try BundleInfo.read(appAt: appURL) }.value
            try await step(.sign) {
                try await signer.sign(appAt: appURL, certificate: material, options: request.options)
            }
            let signed = work.appendingPathComponent("signed.ipa")
            try await step(.package) {
                try await installer.package(appAt: appURL, into: signed)
            }
            // Signing may have changed these; the manifest must match the signed app.
            let signedInfo = (try? await Task.detached { try BundleInfo.read(appAt: appURL) }.value) ?? info
            try await step(.install) {
                switch model.installMethod {
                case .manifestServer:
                    try await installThroughManifestServer(signed, info: signedInfo, model: model)
                case .pairing:
                    try await installThroughPairing(signed, info: signedInfo, model: model)
                }
            }

            let record = InstalledApp(
                bundleID: signedInfo.bundleID, name: signedInfo.name, version: signedInfo.version, build: signedInfo.build,
                sourceURL: request.ipa.origin?.sourceURL, origin: request.ipa.origin,
                installedAt: Date(), certificateID: request.certificate.id, iconURL: request.ipa.iconURL)
            installed = record
            await model.didInstall(record, from: request.ipa, info: info)
            return record
        } catch {
            if failure == nil { failure = error.localizedDescription }
            return nil
        }
    }

    private func installThroughManifestServer(_ signed: URL, info: BundleInfo, model: MobileModel) async throws {
        guard let manifestServer = model.manifestServer else { throw InstallJobError.noManifestServer }
        installDetail = "Starting the local server..."
        installProgressLabel = "iOS is fetching the app"
        let stages = try await model.installer.install(
            ipaAt: signed, bundleIdentifier: info.bundleID,
            version: info.version, title: info.name, manifestServer: manifestServer)
        var handed = false
        for try await stage in stages {
            switch stage {
            case .opened:
                installDetail = "Confirm Install in the alert iOS shows."
            case .manifestFetched:
                // iOS asked for the IPA: it has the manifest from the manifest server.
                installDetail = "iOS is fetching the app..."
            case .downloading(let sent, let total):
                installFraction = total > 0 ? Double(sent) / Double(total) : nil
            case .handedToIOS:
                handed = true
                installFraction = 1
            }
        }
        guard handed else { throw InstallJobError.notHandedOver }
        installDetail = "Handed to iOS: confirm Install in the alert if it is still showing, then watch the Home Screen."
    }

    /// No manifest and no iOS alert: the install service takes the IPA, reports its own progress
    /// and returns once the app is installed.
    private func installThroughPairing(_ signed: URL, info: BundleInfo, model: MobileModel) async throws {
        guard let pairingFile = PairingKeychain.load() else { throw InstallJobError.noPairingFile }
        installDetail = "Connecting..."
        installProgressLabel = "Installing through pairing"
        try await model.pairing.install(
            ipaAt: signed, bundleIdentifier: info.bundleID, pairingFile: pairingFile
        ) { [weak self] stage in
            Task { @MainActor in self?.apply(stage) }
        }
        installFraction = 1
        installDetail = Self.installedText
    }

    private static let installedText = "Installed"

    private func apply(_ stage: PairingStage) {
        // The service's last callback can land after its call returned; "Installed" wins.
        guard installed == nil, installDetail != Self.installedText else { return }
        switch stage {
        case .connecting:
            installDetail = "Connecting..."
            installFraction = nil
        case .uploading(let sent, let total):
            let fraction = total > 0 ? min(1, Double(sent) / Double(total)) : nil
            installFraction = fraction
            installDetail = fraction.map { "Uploading \(Int($0 * 100))%" } ?? "Uploading..."
        case .installing(let percent):
            let clamped = max(0, min(100, percent))
            installFraction = Double(clamped) / 100
            installDetail = "Installing \(clamped)%"
        case .finished:
            installFraction = 1
            installDetail = Self.installedText
        }
    }

    private func step<Value>(_ step: Step, _ body: () async throws -> Value) async throws -> Value {
        phases[step] = .running
        do {
            let value = try await body()
            phases[step] = .done
            return value
        } catch {
            let message = error.localizedDescription
            phases[step] = .failed(message)
            failure = message
            throw error
        }
    }

    private static func removeLater(_ directory: URL) {
        let delay = cleanupDelay
        Task.detached(priority: .background) {
            try? await Task.sleep(for: delay)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

enum InstallJobError: LocalizedError {
    case notHandedOver
    /// Cleared between the readiness check and the Install step.
    case noManifestServer
    /// Removed between the readiness check and the Install step.
    case noPairingFile

    var errorDescription: String? {
        switch self {
        case .noPairingFile: "Import a pairing file in Settings > Install on this iPhone, then install again."
        case .notHandedOver: "iOS did not fetch the app. If you tapped Cancel in the alert, install again."
        case .noManifestServer: "Add your manifest server in Settings > Install on this iPhone, then install again."
        }
    }
}
