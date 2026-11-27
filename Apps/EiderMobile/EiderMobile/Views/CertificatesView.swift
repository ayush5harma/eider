import SwiftUI

struct CertificatesView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.certificates.isEmpty {
                    ContentUnavailableView {
                        Label("No Certificates", systemImage: "checkmark.seal")
                    } description: {
                        Text("Add a development, ad hoc or enterprise certificate: its .p12, the password and its provisioning profile.")
                    } actions: {
                        Button("Add Certificate") { model.addingCertificate = true }
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
                    Button { model.addingCertificate = true } label: { Label("Add Certificate", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $model.addingCertificate) { AddCertificateView() }
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
                ExpiryPill(certificate: certificate)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RevocationPill: View {
    let state: RevocationState

    var body: some View {
        switch state {
        case .unknown: Pill(text: "Status Unknown", systemImage: "questionmark")
        case .checking: Pill(text: "Checking", systemImage: "ellipsis")
        case .valid: Pill(text: "Valid", systemImage: "checkmark.shield", tint: .green)
        case .revoked: Pill(text: "Revoked", systemImage: "xmark.shield", tint: .red)
        case .unavailable: Pill(text: "Not Checked", systemImage: "exclamationmark.shield", tint: .orange)
        }
    }
}

struct ExpiryPill: View {
    let certificate: CertificateRecord

    var body: some View {
        let expires = certificate.expires
        let soon = certificate.expires(within: MobileModel.expiryWarning)
        Pill(text: expires < Date() ? "Expired" : "Expires \(Format.date(expires))",
             systemImage: soon ? "exclamationmark.triangle.fill" : "calendar",
             tint: soon ? .red : .secondary)
    }
}

/// Red under a week or past expiry, the point at which it needs replacing.
struct ExpiryText: View {
    let certificate: CertificateRecord

    var body: some View {
        let expires = certificate.expires
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
                    LabeledContent("Name", value: certificate.commonName)
                    if let nickname = certificate.nickname { LabeledContent("Nickname", value: nickname) }
                    LabeledContent("Status") { RevocationPill(state: model.revocation[id] ?? .unknown) }
                    switch model.revocation[id] {
                    case .unavailable(let reason)?:
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    case .revoked(let date?)?:
                        Text("Revoked \(Format.date(date)). Apps signed with it will not open.").font(.footnote).foregroundStyle(.red)
                    default:
                        EmptyView()
                    }
                    LabeledContent("Certificate Expires", value: Format.date(certificate.certificateExpires))
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
