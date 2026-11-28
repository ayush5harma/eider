import os
import SwiftUI
import UIKit

/// The one-time setup for installing on this device (docs/IOS.md): Eider's
/// own root certificate, name-constrained to 127.0.0.1, localhost and the
/// private network ranges, is installed as a profile and fully trusted, after
/// which iOS accepts the app's HTTPS server at the iPhone's Wi-Fi address for
/// itms-services installs. Driven by the authority's status, which probes that
/// server with the system's own trust.
struct InstallSetupSections: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        Section {
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isCheckingReadiness { ProgressView() }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Install on this iPhone")
        }

        if needsCertificateSteps {
            Section {
                step(1, model.installReadiness == .certificateOutdated
                        ? "Install Eider's new certificate" : "Install Eider's certificate",
                     detail: "Tap the button and allow the download. Then open Settings: \"Profile Downloaded\" is at the top; tap it, then Install.")
                Button("Install Eider's Certificate", systemImage: "arrow.down.doc") {
                    Task { await model.openInstallSetupProfile() }
                }
                Button("Open Settings to Install the Profile", systemImage: "gear") {
                    SettingsLink.open(SettingsLink.downloadedProfile, purpose: "downloaded profile")
                }
                step(2, "Trust it for local installs",
                     detail: "Settings > General > About > Certificate Trust Settings, then turn on \"\(Self.certificateName)\".")
                Button("Open Certificate Trust Settings", systemImage: "checkmark.shield") {
                    SettingsLink.open(SettingsLink.certificateTrust, purpose: "certificate trust")
                }
            } header: {
                Text("Setup")
            } footer: {
                Text(setupFooter)
            }
        }

        Section {
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await model.checkInstallReadiness() }
            }
            .disabled(model.isCheckingReadiness)
        }
    }

    private static let certificateName = "Eider Local Install"

    private var needsCertificateSteps: Bool {
        switch model.installReadiness {
        case .notSetUp?, .certificateOutdated?, .needsTrust?, nil: true
        case .needsWiFi?, .unreachable?, .ready?: false
        }
    }

    private var setupFooter: String {
        var text = "The certificate can only vouch for this iPhone's own and private network addresses, so it cannot be used for any public site. Its private key never leaves this device's Keychain."
        if model.installReadiness == .certificateOutdated {
            text += " The old \"\(Self.certificateName)\" profile is no longer used; remove it in Settings > General > VPN & Device Management."
        }
        return text
    }

    @ViewBuilder private var statusIcon: some View {
        switch model.installReadiness {
        case .ready?:
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
        case .needsWiFi?:
            Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.orange)
        case .needsTrust?, .notSetUp?, .certificateOutdated?, .unreachable?:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        case nil:
            Image(systemName: "questionmark.circle").font(.title2).foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch model.installReadiness {
        case .ready?: "Ready"
        case .needsTrust?: "Needs Trust"
        case .notSetUp?: "Not Set Up"
        case .certificateOutdated?: "Install the Certificate Again"
        case .needsWiFi?: "Connect to Wi-Fi"
        case .unreachable?: "Local Network Is Off"
        case nil: "Not Checked"
        }
    }

    private var statusDetail: String {
        switch model.installReadiness {
        case .ready?: "Eider can install signed apps on this device."
        case .needsTrust?: "Install Eider's certificate and turn on full trust for it."
        case .notSetUp?: "A one-time setup lets Eider install apps on this device."
        case .certificateOutdated?:
            "iOS only takes installs served from this iPhone's Wi-Fi address, which the certificate you installed earlier does not cover. Install the new one and trust it."
        case .needsWiFi?: InstallReadiness.wifiMessage
        case .unreachable?:
            "Eider could not reach its own server on this iPhone. Turn on Local Network for Eider in Settings > Privacy & Security > Local Network, then check again."
        case nil: "Eider has not checked yet."
        }
    }

    private func step(_ number: Int, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Opens a page of the Settings app through its private URL scheme.
///
/// Public API only opens the app's own page (`openSettingsURLString`), which is
/// not where either setup step happens. Eider is sideloaded, so the Settings
/// scheme is fair to use; the candidates are tried in order and the first one
/// `open` accepts wins. Which page each lands on is unverified on iOS 27, so the
/// written path stays beside each button.
@MainActor
enum SettingsLink {
    /// The Settings root lists "Profile Downloaded" at the top after Safari
    /// downloaded a profile; the profiles list is the fallback.
    static let downloadedProfile = ["App-prefs:", "App-prefs:General&path=ManagedConfigurationList"]
    static let certificateTrust = [
        "App-prefs:General&path=About/CERT_TRUST_SETTINGS",
        "prefs:root=General&path=About/CERT_TRUST_SETTINGS",
        "App-prefs:",
    ]

    private static let log = Logger(subsystem: "io.github.ayush5harma.EideriOS", category: "install")

    static func open(_ candidates: [String], purpose: String) {
        Task { await openFirst(candidates, purpose: purpose) }
    }

    private static func openFirst(_ candidates: [String], purpose: String) async {
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if await UIApplication.shared.open(url) {
                log.info("settings for \(purpose, privacy: .public) opened with \(candidate, privacy: .public)")
                return
            }
            log.notice("settings for \(purpose, privacy: .public): \(candidate, privacy: .public) did not open")
        }
        log.error("settings for \(purpose, privacy: .public): no candidate opened")
    }
}

/// The setup on its own, for an install that found the device not ready.
/// Closes itself once the status turns ready.
struct InstallSetupView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                InstallSetupSections()
            }
            .navigationTitle("Set Up Installing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            // Coming back from Settings is the moment the answer may have changed.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.checkInstallReadiness() } }
            }
            .onChange(of: model.installReadiness) { _, readiness in
                if readiness == .ready { dismiss() }
            }
        }
    }
}
