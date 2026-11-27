import SwiftUI

struct CertificatesView: View {
    @Environment(MobileModel.self) private var model
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Group {
                if model.certificates.isEmpty {
                    ContentUnavailableView {
                        Label("No Certificates", systemImage: "checkmark.seal")
                    } description: {
                        Text("Add a development, ad hoc or enterprise certificate: its .p12, the password and its provisioning profile.")
                    } actions: {
                        Button("Add Certificate") { adding = true }
                            .primaryActionStyle()
                    }
                } else {
                    List {
                        Section {
                            ForEach(model.certificates) { certificate in
                                NavigationLink(value: certificate.id) {
                                    CertificateRow(
                                        certificate: certificate,
                                        isDefault: certificate.id == model.defaultCertificate?.id,
                                        revocation: model.revocation[certificate.id] ?? .unknown)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Remove", role: .destructive) { Task { await model.removeCertificate(certificate) } }
                                }
                                .swipeActions(edge: .leading) {
                                    Button("Default") { Task { await model.makeDefault(certificate) } }
                                        .tint(.blue)
                                }
                                .contextMenu {
                                    Button("Make Default", systemImage: "star") { Task { await model.makeDefault(certificate) } }
                                    Button("Remove", systemImage: "trash", role: .destructive) { Task { await model.removeCertificate(certificate) } }
                                }
                            }
                        } footer: {
                            Text("Installs sign with the default certificate unless you pick another. Passwords are kept in the Keychain on this device only.")
                        }
                    }
                }
            }
            .navigationTitle("Certificates")
            .navigationDestination(for: UUID.self) { id in
                CertificateDetailView(id: id)
            }
            .settingsToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Label("Add Certificate", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $adding) { AddCertificateView() }
        }
    }
}

private struct CertificateRow: View {
    let certificate: CertificateRecord
    let isDefault: Bool
    let revocation: RevocationState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(certificate.title).font(.headline).lineLimit(1)
                if isDefault { Pill(text: "Default", systemImage: "star.fill", tint: .blue) }
            }
            Text(certificate.profile.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text("\(certificate.profile.teamName) (\(certificate.profile.teamID))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                Pill(text: certificate.profile.kind.label, tint: .purple)
                RevocationPill(state: revocation)
                ExpiryText(certificate: certificate).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RevocationPill: View {
    let state: RevocationState

    var body: some View {
        switch state {
        case .unknown: Pill(text: "Status Unknown", systemImage: "questionmark.circle")
        case .valid: Pill(text: "Valid", systemImage: "checkmark.shield", tint: .green)
        case .revoked: Pill(text: "Revoked", systemImage: "xmark.shield", tint: .red)
        case .unavailable: Pill(text: "Not Checked", systemImage: "exclamationmark.shield", tint: .orange)
        }
    }
}

/// Red under a week or past expiry, the point at which it needs replacing.
struct ExpiryText: View {
    let certificate: CertificateRecord

    var body: some View {
        let expires = certificate.profile.expires
        let expired = expires < Date()
        Text(expired ? "Expired \(Format.date(expires))" : "Expires \(Format.date(expires))")
            .foregroundStyle(certificate.expires(within: MobileModel.expiryWarning) ? .red : .secondary)
    }
}

private struct CertificateDetailView: View {
    @Environment(MobileModel.self) private var model
    let id: UUID

    var body: some View {
        if let certificate = model.certificates.first(where: { $0.id == id }) {
            let profile = certificate.profile
            List {
                Section("Certificate") {
                    LabeledContent("Name", value: certificate.commonName ?? profile.certificateNames.first ?? "Unknown")
                    if let nickname = certificate.nickname { LabeledContent("Nickname", value: nickname) }
                    LabeledContent("Status") { RevocationPill(state: model.revocation[id] ?? .unknown) }
                    LabeledContent("Password", value: certificate.passwordChecked ? "Checked" : "Checked when signing")
                }
                Section("Provisioning Profile") {
                    LabeledContent("Name", value: profile.name)
                    LabeledContent("Type", value: profile.kind.label)
                    LabeledContent("Team", value: "\(profile.teamName) (\(profile.teamID))")
                    LabeledContent("App ID", value: profile.appIDPattern)
                    LabeledContent("Expires") { ExpiryText(certificate: certificate) }
                    LabeledContent("Devices", value: profile.provisionsAllDevices ? "All devices" : "\(profile.provisionedDevices.count)")
                    LabeledContent("Entitlements", value: "\(profile.entitlementKeys.count)")
                    LabeledContent("UUID") { Text(profile.uuid).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Section {
                    if certificate.id != model.defaultCertificate?.id {
                        Button("Make Default") { Task { await model.makeDefault(certificate) } }
                    }
                    Button("Remove Certificate", role: .destructive) { Task { await model.removeCertificate(certificate) } }
                }
            }
            .navigationTitle(certificate.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Certificate Removed", systemImage: "checkmark.seal")
        }
    }
}
