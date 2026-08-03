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
    ]
)
