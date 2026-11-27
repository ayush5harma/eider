import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let mobileProvision = UTType(filenameExtension: "mobileprovision") ?? .data
}

/// A certificate is added as a pair (.p12 and .mobileprovision) with the
/// p12's password. The profile is read as soon as it is picked, so the person
/// sees which team and type they are adding before they add it.
struct AddCertificateView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Picking {
        case p12, profile
    }

    @State private var picking: Picking?
    @State private var p12: (name: String, data: Data)?
    @State private var provision: (name: String, data: Data)?
    @State private var profile: ProvisioningProfile?
    @State private var password = ""
    @State private var nickname = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    fileButton("Certificate", detail: p12?.name ?? "Choose...", systemImage: "key") { picking = .p12 }
                    fileButton("Provisioning Profile", detail: provision?.name ?? "Choose...", systemImage: "doc.badge.gearshape") { picking = .profile }
                } header: {
                    Text("Files")
                }

                if let profile {
                    Section("Profile") {
                        LabeledContent("Name", value: profile.name)
                        LabeledContent("Team", value: "\(profile.teamName) (\(profile.teamID))")
                        LabeledContent("Type", value: profile.kind.label)
                        LabeledContent("Expires", value: Format.date(profile.expires))
                        if let name = profile.certificateNames.first { LabeledContent("Certificate", value: name) }
                    }
                }

                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    TextField("Nickname (optional)", text: $nickname)
                } footer: {
                    Text("The password is stored in the Keychain on this device only, never in a file.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Add") { save() }
                            .disabled(p12 == nil || provision == nil || profile == nil)
                    }
                }
            }
            // One importer for both files: SwiftUI keeps only one per view.
            .fileImporter(
                isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                allowedContentTypes: picking == .profile ? [.mobileProvision] : [.pkcs12]
            ) { outcome in
                let target = picking
                picking = nil
                switch outcome {
                case .success(let url): load(url, as: target)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func fileButton(_ title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage).foregroundStyle(.primary)
                Spacer()
                Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func load(_ url: URL, as target: Picking?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        error = nil
        do {
            let data = try Data(contentsOf: url)
            switch target {
            case .p12?:
                p12 = (url.lastPathComponent, data)
            case .profile?:
                profile = try ProvisioningProfile.parse(data)
                provision = (url.lastPathComponent, data)
            case nil:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard let p12, let provision else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.addCertificate(p12: p12.data, provision: provision.data, password: password, nickname: nickname)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
