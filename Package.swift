// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Eider",
    // iOS is for the on-device app (docs/IOS.md); only EiderCore, EiderSign,
    // EiderInstall and EiderPairing are built for it. EiderKit, the CLI and the Mac app stay macOS-only.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EiderCore", targets: ["EiderCore"]),
        .library(name: "EiderSign", targets: ["EiderSign"]),
        .library(name: "EiderInstall", targets: ["EiderInstall"]),
        .library(name: "EiderPairing", targets: ["EiderPairing"]),
        .library(name: "EiderKit", targets: ["EiderKit"]),
        .executable(name: "eider", targets: ["eider"]),
        .executable(name: "EiderApp", targets: ["EiderApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL.git", from: "3.3.3001"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        // Platform-neutral: sources, catalogs, downloads, update matching.
        .target(name: "EiderCore"),
        // zsign (MIT, zhlynn/zsign), vendored; see Sources/CZsign/UPSTREAM.md.
        // Swift sees only the C header in include/.
        .target(
            name: "CZsign",
            dependencies: [.product(name: "OpenSSL", package: "OpenSSL")],
            exclude: ["LICENSE", "UPSTREAM.md"],
            cxxSettings: [
                .headerSearchPath("zsign"),
                .headerSearchPath("zsign/common"),
            ]
        ),
        // On-device code signing with the user's own certificate.
        .target(
            name: "EiderSign",
            dependencies: [
                "CZsign",
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        // Unpack, repack and install IPAs on the device the app runs on.
        .target(
            name: "EiderInstall",
            dependencies: [
                "EiderSign",
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        // Native/IDeviceFFI (a C API over idevice, jkcoxson/idevice, MIT) as static
        // libraries for iOS, the iOS simulator and the Mac; built by Scripts/build-idevice.sh
        // and published as a release asset (2.7 MB) rather than committed.
        .binaryTarget(
            name: "IDeviceFFI",
            url: "https://github.com/ayush5harma/eider/releases/download/idevice-c8fff6d-2/IDeviceFFI.xcframework.zip",
            checksum: "a702c4430b5a8b551bc3e223a4fafb67c71b689675cba76a059875effe52b883"
        ),
        // Pairing mode: install through the iPhone's own installation service over
        // RemotePairing (LocalDevVPN), with no manifest server. docs/IOS.md, "Pairing mode".
        .target(name: "EiderPairing", dependencies: ["IDeviceFFI"]),
        .target(name: "EiderKit", dependencies: ["EiderCore"]),
        .executableTarget(
            name: "eider",
            dependencies: [
                "EiderKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "EiderApp", dependencies: ["EiderKit"]),
        .testTarget(name: "EiderKitTests", dependencies: ["EiderKit"], exclude: ["Fixtures"]),
        .testTarget(name: "EiderCLITests", dependencies: ["eider", "EiderKit"]),
        .testTarget(name: "EiderSignTests", dependencies: ["EiderSign"]),
        .testTarget(name: "EiderInstallTests", dependencies: ["EiderInstall"]),
        .testTarget(name: "EiderPairingTests", dependencies: ["EiderPairing"]),
    ]
)
