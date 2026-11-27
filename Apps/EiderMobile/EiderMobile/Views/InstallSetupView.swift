import SwiftUI
import UIKit

/// The one-time setup for installing on this device (docs/IOS.md): Eider's
/// own root certificate, name-constrained to 127.0.0.1 and localhost, is
/// installed as a profile and fully trusted, after which iOS accepts the app's
/// loopback HTTPS server for itms-services installs. Driven by the authority's
/// status, which probes that server with the system's own trust.
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

        if model.installReadiness != .ready {
            Section {
                step(1, "Install Eider's certificate",
                     detail: "Tap the button, allow the download, then open Settings > Profile Downloaded > Install.")
                Button("Install Eider's Certificate", systemImage: "arrow.down.doc") {
                    Task { await model.openInstallSetupProfile() }
                }
                step(2, "Trust it for local installs",
                     detail: "Settings > General > About > Certificate Trust Settings, then turn on \"Eider Local Install\".")
                Button("Open Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("The certificate can only vouch for 127.0.0.1 and localhost, so it cannot be used for any other site. Its private key never leaves this device's Keychain.")
            }
        }

        Section {
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await model.checkInstallReadiness() }
            }
            .disabled(model.isCheckingReadiness)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch model.installReadiness {
        case .ready?:
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
        case .needsTrust?, .notSetUp?:
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
        case nil: "Not Checked"
        }
    }

    private var statusDetail: String {
        switch model.installReadiness {
        case .ready?: "Eider can install signed apps on this device."
        case .needsTrust?: "Install Eider's certificate and turn on full trust for it."
        case .notSetUp?: "A one-time setup lets Eider install apps on this device."
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
