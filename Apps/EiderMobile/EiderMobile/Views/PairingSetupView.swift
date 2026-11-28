import SwiftUI
import UniformTypeIdentifiers

/// The setup for the Pairing (fully local) method, in order:
/// 1. a pairing file, made once on a computer this iPhone trusts, kept in the Keychain;
/// 2. and 3. the free LocalDevVPN app, whose loopback VPN is the only way the
///    iPhone's installation service answers Eider's own connection.
/// "Check Again" asks the service (through the VPN) whether the file is accepted.
struct PairingSetupSections: View {
    @Environment(MobileModel.self) private var model
    @State private var importing = false

    /// `.data` already admits any file; the named types make Files show the pairing
    /// extensions as choosable rather than greyed out.
    private static let pairingTypes: [UTType] =
        [.propertyList, .data] + ["mobiledevicepairing", "rppairing"].compactMap { UTType(filenameExtension: $0) }

    /// A pairing file is a small plist; anything larger is not one.
    private static let sizeLimit = 1_000_000

    var body: some View {
        Section {
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isCheckingPairing { ProgressView() }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pairingStatus")
        } header: {
            Text("Install on this iPhone")
        }

        Section {
            SetupStepRow(number: 1, title: "Import a pairing file",
                         detail: "A pairing file is made once on a computer this iPhone trusts. Choose it here, or copy it into Eider's Documents/Pairing folder from a Mac with devicectl; Eider moves it into the Keychain and deletes the copy.")
            if model.hasPairingFile {
                LabeledContent("Pairing File") {
                    Text(model.pairingHost.map(PairingHost.shortened) ?? "Stored")
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pairingFileSaved")
                Button("Remove Pairing File", systemImage: "trash", role: .destructive) {
                    model.removePairingFile()
                }
                .accessibilityIdentifier("pairingRemove")
            }
            Button(model.hasPairingFile ? "Replace Pairing File" : "Import Pairing File", systemImage: "square.and.arrow.down") {
                importing = true
            }
            .accessibilityIdentifier("pairingImport")
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.pairingTypes) { result in
                Task { await handle(result) }
            }
            if let message = model.pairingMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("pairingImportError")
            }

            SetupStepRow(number: 2, title: "Get LocalDevVPN",
                         detail: "A free app that loops this iPhone's traffic back to itself. It sends nothing anywhere else.")
            Button("Get LocalDevVPN", systemImage: "arrow.down.app") {
                Task { await model.openLocalDevVPNStore() }
            }
            .accessibilityIdentifier("pairingGetVPN")

            SetupStepRow(number: 3, title: "Turn on LocalDevVPN",
                         detail: "Eider opens LocalDevVPN, which switches the VPN on and returns here.")
            Button("Turn On LocalDevVPN", systemImage: "network") {
                Task { await model.openLocalDevVPN() }
            }
            .accessibilityIdentifier("pairingTurnOnVPN")
        } header: {
            Text("Setup")
        } footer: {
            Text("A pairing file grants full access to this iPhone, so keep it private. Eider keeps it in the Keychain on this device only and never as a file.")
        }

        Section {
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await model.checkPairing() }
            }
            .disabled(model.isCheckingPairing)
            .accessibilityIdentifier("pairingCheckAgain")
        }
    }

    private func handle(_ result: Result<URL, Error>) async {
        switch result {
        case .failure(let error):
            model.pairingMessage = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= Self.sizeLimit else {
                model.pairingMessage = "\(url.lastPathComponent) is not a pairing file."
                return
            }
            model.pairingMessage = await model.importPairingFile(data)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch (model.hasPairingFile, model.pairingReadiness) {
        case (true, .ready?):
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
        case (true, .vpnOff?):
            Image(systemName: "network.slash").font(.title2).foregroundStyle(.orange)
        case (true, .refused?):
            Image(systemName: "xmark.octagon.fill").font(.title2).foregroundStyle(.red)
        case (true, nil):
            Image(systemName: "questionmark.circle").font(.title2).foregroundStyle(.secondary)
        case (false, _):
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        }
    }

    private var statusTitle: String {
        guard model.hasPairingFile else { return "Import a Pairing File" }
        switch model.pairingReadiness {
        case .ready?: return "Ready"
        case .vpnOff?: return "VPN Off"
        case .refused?: return "Refused"
        case nil: return "Not Checked"
        }
    }

    private var statusDetail: String {
        guard model.hasPairingFile else {
            return "Eider needs a pairing file to install through this iPhone's own installation service."
        }
        switch model.pairingReadiness {
        case .ready?: return "Eider can install signed apps through the pairing file."
        case .vpnOff(let message)?: return "\(message) Turn on LocalDevVPN, then check again."
        case .refused(let message)?: return message
        case nil: return "Eider has not checked yet."
        }
    }
}
