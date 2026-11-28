import EiderCore
import SwiftUI

/// Sign and install one IPA: pick a certificate, adjust the signing options,
/// and watch Unpack, Sign, Package and Install run.
struct InstallSheet: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: InstallRequest

    @State private var job = InstallJob()
    @State private var certificateID: UUID?
    @State private var bundleID = ""
    @State private var displayName = ""
    @State private var version = ""
    @State private var removeSupportedDevices = false
    @State private var enableFileSharing = false
    @State private var removeURLSchemes = false
    @State private var addingCertificate = false
    @State private var settingUp = false
    @State private var validationMessage: String?

    private var ipa: LibraryIPA { request.ipa }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        AppIcon(url: ipa.iconURL, sourceURL: ipa.origin?.sourceURL, side: 56, name: ipa.name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ipa.name).font(.headline)
                            Text([ipa.version, Format.size(ipa.size)].compactMap { $0 }.joined(separator: " \u{00B7} "))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let bundle = ipa.bundleID { Text(bundle).font(.caption).foregroundStyle(.tertiary) }
                        }
                    }
                }

                Section {
                    if model.certificates.isEmpty {
                        Button("Add a Certificate", systemImage: "plus.circle") { addingCertificate = true }
                    } else {
                        Picker("Certificate", selection: $certificateID) {
                            ForEach(model.certificates) { certificate in
                                Text(certificate.title).tag(UUID?.some(certificate.id))
                            }
                        }
                        if let certificate = selectedCertificate {
                            LabeledContent("Profile", value: certificate.profile.name)
                            LabeledContent("Expires") {
                                Text(Format.date(certificate.expires))
                                    .foregroundStyle(certificate.expires(within: MobileModel.expiryWarning) ? .red : .secondary)
                            }
                        }
                    }
                } header: {
                    Text("Certificate")
                } footer: {
                    if model.certificates.isEmpty {
                        Text("Eider signs apps with your own certificate: a .p12, its password and a provisioning profile.")
                    }
                }

                Section("Signing Options") {
                    LabeledContent("Bundle ID") {
                        TextField(request.replacing?.bundleID ?? ipa.bundleID ?? "Keep the app's own", text: $bundleID)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Name") {
                        TextField(ipa.name, text: $displayName).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Version") {
                        TextField(ipa.version ?? "Keep", text: $version)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    Toggle("Remove Supported Devices", isOn: $removeSupportedDevices)
                    Toggle("Enable File Sharing", isOn: $enableFileSharing)
                    Toggle("Remove URL Schemes", isOn: $removeURLSchemes)
                }
                .disabled(job.isRunning)

                Section("Progress") {
                    StepList(job: job)
                    if let fraction = job.installFraction, job.installed == nil {
                        ProgressView(value: fraction)
                            .accessibilityLabel("\(job.installProgressLabel), \(Int(fraction * 100)) percent")
                            .accessibilityIdentifier("installProgress")
                    }
                    if let detail = job.installDetail {
                        Label(detail, systemImage: job.installed == nil ? "info.circle" : "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(job.installed == nil ? Color.secondary : Color.green)
                            .accessibilityIdentifier("installDetail")
                    }
                    if let message = validationMessage ?? job.failure {
                        Text(message).font(.callout).foregroundStyle(.red)
                            .accessibilityIdentifier("installFailure")
                    }
                }
            }
            .navigationTitle("Install")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(job.installed == nil ? "Cancel" : "Done") { dismiss() }
                        .disabled(job.isRunning)
                }
            }
            // The one action of the sheet as a wide glass capsule in reach of a thumb.
            .bottomBar {
                if job.installed == nil {
                    Button {
                        start()
                    } label: {
                        HStack(spacing: 8) {
                            if job.isRunning { ProgressView().tint(.white) }
                            Text(job.isRunning ? "Installing..." : job.failure == nil ? "Install" : "Try Again")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .primaryActionStyle()
                    .controlSize(.large)
                    .disabled(selectedCertificate == nil || job.isRunning)
                    .accessibilityIdentifier("installButton")
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
            .interactiveDismissDisabled(job.isRunning)
            .sheet(isPresented: $addingCertificate) { AddCertificateView() }
            .sheet(isPresented: $settingUp) { InstallSetupView() }
            .onAppear {
                certificateID = certificateID ?? model.defaultCertificate?.id
                if bundleID.isEmpty, let replacing = request.replacing, replacing.bundleID != ipa.bundleID {
                    bundleID = replacing.bundleID
                }
            }
            .onChange(of: model.certificates) {
                if selectedCertificate == nil { certificateID = model.defaultCertificate?.id }
            }
        }
    }

    private var selectedCertificate: CertificateRecord? {
        model.certificates.first { $0.id == certificateID }
    }

    private func start() {
        guard let certificate = selectedCertificate else { return }
        func value(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        validationMessage = nil
        if let id = value(bundleID), !BundleIdentifier.isValid(id) {
            validationMessage = "\(id) is not a valid bundle id."
            return
        }
        let options = SignOptions(
            bundleIdentifier: value(bundleID), displayName: value(displayName), version: value(version),
            removeSupportedDevices: removeSupportedDevices, enableFileSharing: enableFileSharing,
            removeURLSchemes: removeURLSchemes)
        let request = InstallJob.Request(
            ipa: ipa, ipaURL: model.library.fileURL(of: ipa), certificate: certificate, options: options)
        Task {
            // Not trusted yet: the one-time setup, not a failure at the last step.
            await model.checkInstallSetup()
            // No Wi-Fi is not something the setup can fix: say so here. Pairing goes through the
            // loopback VPN and needs no Wi-Fi.
            if model.installMethod == .manifestServer, model.installReadiness == .needsWiFi {
                validationMessage = InstallReadiness.wifiMessage
                return
            }
            guard model.isInstallSetupReady else {
                settingUp = true
                return
            }
            await job.run(request, model: model)
        }
    }
}

/// Unpack, Sign, Package, Install with each one's state.
struct StepList: View {
    let job: InstallJob

    var body: some View {
        ForEach(InstallJob.Step.allCases) { step in
            HStack(spacing: 10) {
                icon(for: job.phase(of: step)).frame(width: 20)
                Text(step.rawValue)
                    .foregroundStyle(job.phase(of: step) == .waiting ? .secondary : .primary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(label(for: job.phase(of: step)))
        }
    }

    @ViewBuilder private func icon(for phase: InstallJob.Phase) -> some View {
        switch phase {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func label(for phase: InstallJob.Phase) -> String {
        switch phase {
        case .waiting: "Waiting"
        case .running: "In progress"
        case .done: "Done"
        case .failed(let message): "Failed: \(message)"
        }
    }
}
