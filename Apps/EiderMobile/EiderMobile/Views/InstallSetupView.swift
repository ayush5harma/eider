import os
import SwiftUI
import UIKit

/// The one-time setup for installing on this device (docs/IOS.md), in order:
/// 1. the manifest server: appstored refuses a manifest the iPhone serves
///    itself ("The manifest URL isn't external", iOS 27.3, measured
///    2026-11-28), so the manifest comes from another computer while the IPA
///    still comes from this iPhone;
/// 2. and 3. Eider's own root certificate, name-constrained to 127.0.0.1,
///    localhost and the private network ranges, installed as a profile and
///    fully trusted, after which iOS accepts the app's HTTPS server at the
///    iPhone's Wi-Fi address for the IPA.
/// Driven by the readiness check, which asks the manifest server and probes
/// the local server with the system's own trust.
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

        Section {
            step(1, "Add your manifest server",
                 detail: "iOS only takes an install whose manifest comes from another computer; the app itself still comes from this iPhone. Paste your manifest server's address, like https://<computer>/eider/manifest/<secret>.plist.")
            ManifestServerRow()
            if needsCertificateSteps {
                step(2, model.installReadiness == .certificateOutdated
                        ? "Install Eider's new certificate" : "Install Eider's certificate",
                     detail: "Tap the button and allow the download. Then open Settings: \"Profile Downloaded\" is at the top; tap it, then Install.")
                Button("Install Eider's Certificate", systemImage: "arrow.down.doc") {
                    Task { await model.openInstallSetupProfile() }
                }
                Button("Open Settings to Install the Profile", systemImage: "gear") {
                    SettingsLink.open(SettingsLink.downloadedProfile, purpose: "downloaded profile")
                }
                step(3, "Trust it for local installs",
                     detail: "Settings > General > About > Certificate Trust Settings, then turn on \"\(Self.certificateName)\".")
                Button("Open Certificate Trust Settings", systemImage: "checkmark.shield") {
                    SettingsLink.open(SettingsLink.certificateTrust, purpose: "certificate trust")
                }
            }
        } header: {
            Text("Setup")
        } footer: {
            Text(setupFooter)
        }

        Section {
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await model.checkInstallReadiness() }
            }
            .disabled(model.isCheckingReadiness)
        }
    }

    private static let certificateName = "Eider Local Install"

    /// Shown until the local checks pass. While the manifest server is missing
    /// or silent the certificate was not looked at, so its steps stay listed.
    private var needsCertificateSteps: Bool {
        switch model.installReadiness {
        case .needsManifestServer?, .manifestServerUnreachable?, .notSetUp?, .certificateOutdated?, .needsTrust?, nil: true
        case .needsWiFi?, .unreachable?, .ready?: false
        }
    }

    private var setupFooter: String {
        var text = "The manifest server's address holds a secret, so Eider keeps it in the Keychain and shows it masked."
        guard needsCertificateSteps else { return text }
        text += " The certificate can only vouch for this iPhone's own and private network addresses, so it cannot be used for any public site. Its private key never leaves this device's Keychain."
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
        case .needsManifestServer?, .manifestServerUnreachable?, .needsTrust?, .notSetUp?, .certificateOutdated?,
             .unreachable?:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        case nil:
            Image(systemName: "questionmark.circle").font(.title2).foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch model.installReadiness {
        case .ready?: "Ready"
        case .needsManifestServer?: "Add Your Manifest Server"
        case .manifestServerUnreachable?: "Manifest Server Not Answering"
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
        case .needsManifestServer?:
            "iOS refuses an install manifest served by this iPhone itself. Add the manifest server on your computer in step 1."
        case .manifestServerUnreachable?:
            "Eider could not get an answer from \(model.manifestServer.map(ManifestServerAddress.masked) ?? "the manifest server"). Check that it is running, that this iPhone is on its network, and that its certificate is trusted here."
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

/// The manifest server's address: masked once saved, with Edit and Clear; a
/// field with Paste and Save while there is none or while editing. Editing
/// starts empty so the stored secret is never shown again.
private struct ManifestServerRow: View {
    @Environment(MobileModel.self) private var model
    @State private var text = ""
    @State private var editing = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        if let saved = model.manifestServer, !editing {
            LabeledContent("Manifest Server") {
                Text(ManifestServerAddress.masked(saved))
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("manifestServerSaved")
            Button("Edit Manifest Server", systemImage: "pencil") {
                text = ""
                message = nil
                editing = true
            }
            .accessibilityIdentifier("manifestServerEdit")
            Button("Clear Manifest Server", systemImage: "trash", role: .destructive) {
                Task { await model.clearManifestServer() }
            }
            .accessibilityIdentifier("manifestServerClear")
        } else {
            TextField("https://computer/eider/manifest/secret.plist", text: $text)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(save)
                .accessibilityLabel("Manifest Server URL")
                .accessibilityIdentifier("manifestServerField")
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        if let first = strings.first { text = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("manifestServerPaste")
                Spacer()
                if editing {
                    Button("Cancel") {
                        editing = false
                        message = nil
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel Editing Manifest Server")
                    .accessibilityIdentifier("manifestServerCancel")
                }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Save Manifest Server")
                    .accessibilityIdentifier("manifestServerSave")
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("manifestServerError")
            }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            if let refusal = await model.saveManifestServer(text) {
                message = refusal
            } else {
                message = nil
                text = ""
                editing = false
            }
        }
    }
}

/// Opens a page of the Settings app through its private URL scheme.
///
/// Public API only opens the app's own page (`openSettingsURLString`), which is
/// not where either setup step happens. Eider is sideloaded, so the Settings
/// scheme is fair to use; the candidates are tried in order and the first one
/// `open` accepts wins, logged by name. The written path stays beside each
/// button in case a later iOS moves the page.
///
/// Measured on iOS 27.3, 2026-11-28, opening each URL in Settings:
/// `prefs:root=General&path=About/CERT_TRUST_SETTINGS` and
/// `settings-navigation://com.apple.Settings.General/About/CERT_TRUST_SETTINGS`
/// land on Certificate Trust Settings; `App-prefs:root=General&path=About/...`
/// and `App-prefs:General&path=About/...` land on the Apps page instead, so
/// neither is tried. `App-prefs:` (the root) showed "Profile Downloaded" at the
/// top after Safari downloaded a profile.
@MainActor
enum SettingsLink {
    static let downloadedProfile = ["App-prefs:", "prefs:root=General&path=ManagedConfigurationList"]
    static let certificateTrust = [
        "prefs:root=General&path=About/CERT_TRUST_SETTINGS",
        "settings-navigation://com.apple.Settings.General/About/CERT_TRUST_SETTINGS",
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
