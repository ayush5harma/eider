import AppKit
import EiderKit
import SwiftUI
import UniformTypeIdentifiers

struct InstallOptionsSheet: View {
    @Bindable var model: AppModel
    @State private var choosingDylibs = false
    @State private var choosingFolder = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let pending = model.pendingInstall {
            VStack(alignment: .leading, spacing: 12) {
                Text("Install \(pending.request.title)").font(.title3.bold())
                Form {
                    Toggle("Run in the Mac idiom", isOn: draft(\.macIdiom))
                    Toggle("Keychain shim", isOn: draft(\.keychainShim))
                    TextField("Display name", text: draft(\.displayName), prompt: Text("Keep the app's own"))
                    TextField("Bundle id", text: draft(\.bundleID), prompt: Text("Keep the app's own"))
                    Toggle("Remove app extensions", isOn: draft(\.removeExtensions))
                    Toggle("Reset the app's data before installing", isOn: draft(\.resetData))
                    dylibRow(pending.draft.extraDylibs)
                    LabeledContent("Install location") {
                        Text(pending.draft.destination.path).lineLimit(1).truncationMode(.middle)
                        Button("Choose...") { choosingFolder = true }
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelPendingInstall(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Install") { model.confirmPendingInstall(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 520)
            .fileImporter(isPresented: $choosingDylibs, allowedContentTypes: [UTType(filenameExtension: "dylib") ?? .data], allowsMultipleSelection: true) {
                if case .success(let urls) = $0 { model.pendingInstall?.draft.extraDylibs.append(contentsOf: urls) }
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) {
                if case .success(let url) = $0 { model.pendingInstall?.draft.destination = url }
            }
        }
    }

    private func dylibRow(_ dylibs: [URL]) -> some View {
        LabeledContent("Extra dylibs") {
            VStack(alignment: .trailing) {
                ForEach(dylibs, id: \.self) { url in
                    HStack {
                        Text(url.lastPathComponent)
                        Button {
                            model.pendingInstall?.draft.extraDylibs.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                    }
                }
                Button("Add...") { choosingDylibs = true }
            }
        }
    }

    private func draft<T>(_ keyPath: WritableKeyPath<InstallOptionsDraft, T>) -> Binding<T> {
        Binding(
            get: { model.pendingInstall?.draft[keyPath: keyPath] ?? InstallOptionsDraft(destination: model.settings.defaultInstallLocation)[keyPath: keyPath] },
            set: { model.pendingInstall?.draft[keyPath: keyPath] = $0 })
    }
}

/// A link from outside is untrusted: the whole address is shown, selectable,
/// before anything happens, and the default button is the safe one.
struct DeepLinkSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let link = model.pendingLink {
            VStack(alignment: .leading, spacing: 12) {
                Text("A link wants Eider to \(link.verb)").font(.title3.bold())
                Text("Only continue if you trust where this link came from. The full address is:")
                Text(link.url.absoluteString)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.dismissPendingLink(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                    Button("Continue") { Task { await model.confirmPendingLink() } }
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }
}

struct DiagnosisSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.diagnosis {
            case .idle:
                EmptyView()
            case .running(let name):
                Text("Diagnosing \(name)").font(.title3.bold())
                ProgressView("Opening the app and watching what happens...")
            case .finished(let name, .running(let pid)):
                Text("\(name) is running").font(.title3.bold())
                Text("It stayed up after opening (process \(pid)). Nothing to fix.")
            case .finished(let name, .failed(let diagnosis)):
                Text("\(name) did not stay open").font(.title3.bold())
                Text(diagnosis.summary)
                LabeledContent("Code") { Text(diagnosis.code.rawValue).font(.body.monospaced()).textSelection(.enabled) }
                if !diagnosis.evidence.isEmpty {
                    Text("Evidence").font(.headline)
                    ScrollView {
                        Text(diagnosis.evidence.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct ReleaseCheckSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.releaseCheck {
            case .idle: EmptyView()
            case .checking: ProgressView("Asking GitHub for the latest release...")
            case .upToDate(let current):
                Text("Eider is up to date").font(.title3.bold())
                Text("You have version \(current), the latest release.")
            case .newer(let version, let url):
                Text("Eider \(version) is available").font(.title3.bold())
                Link("Open the release page", destination: url)
            case .failed(let message):
                Text("Could not check").font(.title3.bold())
                Text(message)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct SettingsView: View {
    let model: AppModel
    @State private var choosing = false

    var body: some View {
        Form {
            LabeledContent("Default install location") {
                Text(model.settings.defaultInstallLocation.path).lineLimit(1).truncationMode(.middle)
                Button("Choose...") { choosing = true }
                Button("Use /Applications") { model.setDefaultInstallLocation(InstallOptions.defaultDestination) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) {
            if case .success(let url) = $0 { model.setDefaultInstallLocation(url) }
        }
    }
}
