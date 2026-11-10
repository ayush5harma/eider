// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Eider",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EiderKit", targets: ["EiderKit"]),
        .executable(name: "eider", targets: ["eider"]),
        .executable(name: "EiderApp", targets: ["EiderApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "EiderKit"),
        .executableTarget(
            name: "eider",
            dependencies: [
                "EiderKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "EiderApp", dependencies: ["EiderKit"]),
        .testTarget(name: "EiderKitTests", dependencies: ["EiderKit"]),
    ]
)
