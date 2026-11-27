import Foundation
import XCTest

/// A tiny arm64 iOS app built at test time: an executable linked against one
/// embedded dylib, plus one app extension, so nested signing is exercised.
enum ProbeApp {
    static let bundleIdentifier = "io.github.ayush5harma.EiderSignProbe"

    /// Builds Probe.app inside `directory`; skips the test when the iOS SDK
    /// is not installed.
    static func build(in directory: URL, bundleIdentifier: String = ProbeApp.bundleIdentifier) throws -> URL {
        guard (try? TestMaterial.run("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"], in: directory)) != nil else {
            throw XCTSkip("The iOS SDK is not installed (xcrun --sdk iphoneos).")
        }
        let app = directory.appendingPathComponent("Probe.app", isDirectory: true)
        let widget = app.appendingPathComponent("PlugIns/Widget.appex", isDirectory: true)
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        for folder in [app, widget, frameworks] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let sources = directory.appendingPathComponent("probe-src", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "int eider_probe_value(void) { return 42; }\n"
            .write(to: sources.appendingPathComponent("lib.c"), atomically: true, encoding: .utf8)
        try "extern int eider_probe_value(void);\nint main(void) { return eider_probe_value() == 42 ? 0 : 1; }\n"
            .write(to: sources.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)
        try "int main(void) { return 0; }\n"
            .write(to: sources.appendingPathComponent("widget.c"), atomically: true, encoding: .utf8)

        let clang = ["--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios17.0"]
        try TestMaterial.run("/usr/bin/xcrun", clang + [
            "-dynamiclib", "-install_name", "@rpath/libEiderProbe.dylib",
            "-o", frameworks.appendingPathComponent("libEiderProbe.dylib").path, "lib.c",
        ], in: sources)
        try TestMaterial.run("/usr/bin/xcrun", clang + [
            "-o", app.appendingPathComponent("Probe").path, "main.c",
            frameworks.appendingPathComponent("libEiderProbe.dylib").path,
            "-Wl,-rpath,@executable_path/Frameworks",
        ], in: sources)
        try TestMaterial.run("/usr/bin/xcrun", clang + [
            "-o", widget.appendingPathComponent("Widget").path, "widget.c",
        ], in: sources)

        try writePlist([
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "Probe",
            "CFBundleName": "Probe",
            "CFBundleDisplayName": "Probe",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "MinimumOSVersion": "17.0",
            "UIDeviceFamily": [1, 2],
            "UISupportedDevices": ["iPhone17,1"],
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["eiderprobe"]]],
        ], to: app.appendingPathComponent("Info.plist"))
        try writePlist([
            "CFBundleIdentifier": "\(bundleIdentifier).widget",
            "CFBundleExecutable": "Widget",
            "CFBundleName": "Widget",
            "CFBundlePackageType": "XPC!",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "MinimumOSVersion": "17.0",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
        ], to: widget.appendingPathComponent("Info.plist"))
        return app
    }

    static func info(_ app: URL, _ relative: String = "") throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent(relative).appendingPathComponent("Info.plist"))
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    }

    private static func writePlist(_ plist: [String: Any], to url: URL) throws {
        // Binary, as in an IPA from the App Store or Xcode.
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: url)
    }
}
