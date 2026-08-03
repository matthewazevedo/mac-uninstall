// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacUninstall",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacUninstallCore", targets: ["MacUninstallCore"]),
        .executable(name: "MacUninstall", targets: ["MacUninstallApp"]),
    ],
    targets: [
        .target(
            name: "MacUninstallCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MacUninstallApp",
            dependencies: ["MacUninstallCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacUninstallCoreTests",
            dependencies: ["MacUninstallCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
