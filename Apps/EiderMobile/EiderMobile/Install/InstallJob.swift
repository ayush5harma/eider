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

    let id = UUID()
    private(set) var phases: [Step: Phase] = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .waiting) })
    private(set) var isRunning = false
    private(set) var installed: InstalledApp?
    private(set) var failure: String?

    func phase(of step: Step) -> Phase { phases[step] ?? .waiting }

    /// Runs every step in order and stops at the first failure. Returns the
    /// record to keep when the app reached the device.
    @discardableResult
    func run(_ request: Request, model: MobileModel) async -> InstalledApp? {
        guard !isRunning else { return nil }
        isRunning = true
        failure = nil
        installed = nil
        phases = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .waiting) })
        defer { isRunning = false }

        let signer = model.signer
        let installer = model.installer
        let work = model.paths.work.appendingPathComponent(id.uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }

        do {
            let material = try await model.certificateStore.material(for: request.certificate.id)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let appURL = try await step(.unpack) {
                try await installer.unpack(ipaAt: request.ipaURL, into: work)
            }
            let info = try await Task.detached { try BundleInfo.read(appAt: appURL) }.value
            try await step(.sign) {
                try await signer.sign(appAt: appURL, certificate: material, options: request.options)
            }
            let signed = work.appendingPathComponent("signed.ipa")
            try await step(.package) {
                try await installer.package(appAt: appURL, into: signed)
            }
            let bundleID = request.options.bundleIdentifier ?? info.bundleID
            let version = request.options.version ?? info.version
            let name = request.options.displayName ?? info.name
            try await step(.install) {
                try await installer.install(ipaAt: signed, bundleIdentifier: bundleID, version: version, title: name)
            }

            let record = InstalledApp(
                bundleID: bundleID, name: name, version: version, build: info.build,
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
}
