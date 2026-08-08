// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacUninstall",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacUninstallCore", targets: ["MacUninstallCore"]),
        .executable(name: "MacUninstall", targets: ["MacUninstallApp"]),
        .executable(name: "com.macuninstall.helper", targets: ["MacUninstallHelper"]),
    ],
    dependencies: [
        // Only the app links this. The helper runs as root and stays on pure
        // Foundation, so nothing about updating reaches the privileged process.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .target(
            name: "MacUninstallCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The model layer, split out from the executable for one reason: a SwiftPM
        // executable target cannot be imported by tests, and "which items are ticked
        // by default" is part of the safety story, not a detail of the views.
        .target(
            name: "MacUninstallAppCore",
            dependencies: ["MacUninstallCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MacUninstallApp",
            dependencies: [
                "MacUninstallCore",
                "MacUninstallAppCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Runs as root under launchd, installed from inside the app bundle by
        // SMAppService. Links only MacUninstallCore, which is pure Foundation, so no
        // UI framework is ever loaded into a privileged process.
        .executableTarget(
            name: "MacUninstallHelper",
            dependencies: ["MacUninstallCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacUninstallCoreTests",
            dependencies: ["MacUninstallCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacUninstallAppCoreTests",
            dependencies: ["MacUninstallAppCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
