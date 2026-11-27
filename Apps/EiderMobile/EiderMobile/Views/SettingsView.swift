import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

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
                Section {
                    LabeledContent("Method", value: "On this device")
                } header: {
                    Text("Install Method")
                } footer: {
                    Text("Eider installs signed apps on this iPhone or iPad through a local server only it can vouch for. The one-time setup for it will appear here when the installer is ready.")
                }

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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
