import ArgumentParser
import EiderKit

extension InterfaceScale: ExpressibleByArgument {
    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

/// The values, for help text.
let interfaceSizeValues = "auto, 77 (iPad), 85, 100, 115 or mac (Mac idiom)"

struct ScaleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scale",
        abstract: "Show or set how large an installed app draws (its interface size).",
        discussion: """
            iPad apps draw at 77% on the Mac. Auto is 100% on the built-in display \
            (as Apple's own apps draw) and a little more on a desk display. The app \
            picks a change up when it next opens: no reinstall.
            """
    )

    @Argument(help: "The app's bundle id (or --all).")
    var bundleID: String?

    @Argument(help: "The size: \(interfaceSizeValues). Leave out to show the current one.")
    var size: InterfaceScale?

    @Flag(name: .customLong("all"), help: "Every installed app (with a size: set it on all of them).")
    var all = false

    @OptionGroup var common: CommonOptions

    private struct Entry: Encodable {
        let bundleID: String
        let name: String
        let state: InterfaceScaleState
        let message: String?
    }

    private struct Payload: Encodable { let apps: [Entry] }

    /// With --all the one positional is the size, so `eider scale --all auto` reads naturally.
    private var target: (ids: String?, size: InterfaceScale?) {
        guard all, let bundleID else { return (bundleID, size) }
        return (nil, InterfaceScale(argument: bundleID))
    }

    func validate() throws {
        if all {
            guard size == nil else { throw ValidationError("With --all, give only the size.") }
            if let bundleID, InterfaceScale(argument: bundleID) == nil {
                throw ValidationError("\(bundleID) is not a size: use \(interfaceSizeValues).")
            }
        } else {
            guard let bundleID else { throw ValidationError("Give a bundle id, or --all.") }
            try requireBundleID(bundleID)
        }
    }

    func run() async throws {
        try await common.guarded { output in
            let operations = AppOperations()
            var ids = [String]()
            if let id = target.ids { ids = [id] } else { ids = try await operations.library.all().map(\.bundleID) }
            var entries: [Entry] = []
            for id in ids {
                var message: String?
                if let size = target.size {
                    message = try await operations.setInterfaceScale(size, bundleID: id).message
                }
                let state = try await operations.interfaceScaleState(bundleID: id)
                let name = try await operations.library.app(bundleID: id)?.name ?? id
                entries.append(Entry(bundleID: id, name: name, state: state, message: message))
            }
            let lines = entries.map { entry in
                entry.message.map { "\(entry.name): \($0). It applies when \(entry.name) next opens." }
                    ?? "\(entry.name): \(entry.state.summary)"
            }
            output.result(Payload(apps: entries), text: lines.isEmpty ? "No apps are installed." : lines.joined(separator: "\n"))
        }
    }
}
