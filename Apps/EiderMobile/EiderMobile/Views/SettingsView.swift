import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MobileModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private static let repository = URL(string: "https://github.com/ayush5harma/eider")!

    private struct Licence: Identifiable {
        let name: String
        let licence: String
        let url: URL
        var id: String { name }
    }

    private static let licences: [Licence] = [
        Licence(name: "zsign", licence: "MIT", url: URL(string: "https://github.com/zhlynn/zsign")!),
        Licence(name: "OpenSSL", licence: "Apache-2.0", url: URL(string: "https://github.com/krzyzanowskim/OpenSSL")!),
        Licence(name: "swift-certificates", licence: "Apache-2.0", url: URL(string: "https://github.com/apple/swift-certificates")!),
        Licence(name: "ZIPFoundation", licence: "MIT", url: URL(string: "https://github.com/weichsel/ZIPFoundation")!),
    ]

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                InstallSetupSections()

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link(destination: Self.repository) {
                        Label("Eider on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }

                Section("Licences") {
                    ForEach(Self.licences) { item in
                        Link(destination: item.url) {
                            LabeledContent(item.name, value: item.licence)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.checkInstallSetup() }
            // Back from Settings, where trust is turned on, or from the VPN app: ask again.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.checkInstallSetup() } }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
