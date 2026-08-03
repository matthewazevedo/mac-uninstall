import XCTest
@testable import MacUninstallCore

/// Regressions for two bugs found by scanning a real Mac. Both would have caused
/// data loss, and neither was visible against synthetic fixtures.
final class CrossContaminationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallContamination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeFile(_ relative: String, contents: String = "x") throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func scanner(_ locations: [SearchLocation]) -> LeftoverScanner {
        LeftoverScanner(
            locations: locations,
            options: .init(measureSizes: false, safetyCheck: { _ in true })
        )
    }

    // MARK: - Bug A: system preferences must never be claimed

    /// macOS registries name every installed app. A mention is not ownership, and
    /// deleting `com.apple.dock.plist` would wipe the user's Dock.
    func testDeepInspectionNeverClaimsApplePreferences() async throws {
        let prefs = root.appending(path: "Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)

        for name in [
            "com.apple.dock.plist",
            "com.apple.corespotlightui.plist",
            "com.apple.networkextension.plist",
            "com.apple.universalaccessAuthWarning.plist",
        ] {
            try makeFile("Preferences/\(name)", contents: "mentions com.acmesoft.Sketchpad everywhere")
        }

        let identity = AppIdentity(
            bundleURL: root.appending(path: "Sketchpad.app"),
            bundleID: "com.acmesoft.Sketchpad",
            displayName: "Sketchpad"
        )

        let result = await scanner([.init(url: prefs, category: .preferences)]).scan(for: identity)

        XCTAssertTrue(
            result.leftovers.isEmpty,
            "Claimed Apple system files: \(result.leftovers.map(\.url.lastPathComponent))"
        )
    }

    /// Content evidence is genuinely useful for opaque names, but it is weaker than
    /// a name match and must never be pre-selected for deletion.
    func testDeepInspectionHitsAreNeverAutoSelected() async throws {
        let prefs = root.appending(path: "Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try makeFile(
            "Preferences/com.todesktop.230313mzl4w4u92.plist",
            contents: "<plist>com.acmesoft.Sketchpad</plist>"
        )

        let identity = AppIdentity(
            bundleURL: root.appending(path: "Sketchpad.app"),
            bundleID: "com.acmesoft.Sketchpad",
            displayName: "Sketchpad"
        )

        let result = await scanner([.init(url: prefs, category: .preferences)]).scan(for: identity)
        let hit = try XCTUnwrap(result.leftovers.first)
        XCTAssertEqual(hit.confidence, .possible)
        XCTAssertFalse(hit.confidence.selectedByDefault)
    }

    // MARK: - Bug B: embedded third-party frameworks are not evidence

    func testEmbeddedThirdPartyFrameworksAreNotTreatedAsAppIdentifiers() throws {
        let bundle = root.appending(path: "Tailscale.app")
        let frameworks = bundle.appending(path: "Contents/Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)

        try writeBundle(
            at: frameworks.appending(path: "Sparkle.framework"),
            plistPath: "Resources/Info.plist",
            bundleID: "org.sparkle-project.Sparkle"
        )
        try writeBundle(
            at: bundle.appending(path: "Contents/Library/LoginItems/Helper.app"),
            plistPath: "Contents/Info.plist",
            bundleID: "io.tailscale.ipn.macsys.login-item-helper"
        )
        try writeBundle(at: bundle, plistPath: "Contents/Info.plist", bundleID: "io.tailscale.ipn.macsys")

        let identity = try XCTUnwrap(AppScanner().readIdentity(at: bundle))

        XCTAssertTrue(
            identity.helperBundleIDs.contains("io.tailscale.ipn.macsys.login-item-helper"),
            "The app's own login item is genuine evidence"
        )
        XCTAssertFalse(
            identity.helperBundleIDs.contains("org.sparkle-project.Sparkle"),
            "A shared updater framework must never be treated as this app's identifier"
        )
    }

    /// The end-to-end consequence: uninstalling one app must not touch another's cache.
    func testScanDoesNotClaimAnotherAppsSparkleCache() async throws {
        let caches = root.appending(path: "Caches")
        try makeFile("Caches/app.cotypist.Cotypist/org.sparkle-project.Sparkle/data.bin")
        try makeFile("Caches/io.tailscale.ipn.macsys/own.bin")

        let identity = AppIdentity(
            bundleURL: root.appending(path: "Tailscale.app"),
            bundleID: "io.tailscale.ipn.macsys",
            displayName: "Tailscale",
            // Post-fix, Sparkle is filtered out at discovery; assert the scan is clean
            // even if something ever reintroduces it upstream.
            helperBundleIDs: ["io.tailscale.ipn.macsys.login-item-helper"]
        )

        let result = await scanner([
            .init(url: caches, category: .caches, childrenOnly: false)
        ]).scan(for: identity)

        let paths = result.leftovers.map(\.url.path)
        XCTAssertFalse(
            paths.contains { $0.contains("app.cotypist.Cotypist") },
            "Claimed another app's data: \(paths)"
        )
        XCTAssertTrue(paths.contains { $0.hasSuffix("io.tailscale.ipn.macsys") })
    }

    func testBelongsToAppAcceptsOwnNamespaceAndRejectsForeignOne() {
        let identity = AppIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/T.app"),
            bundleID: "io.tailscale.ipn.macsys",
            displayName: "Tailscale"
        )
        XCTAssertTrue(AppScanner.belongsToApp("io.tailscale.ipn.macsys.helper", identity: identity))
        XCTAssertTrue(AppScanner.belongsToApp("io.tailscale.other", identity: identity))
        XCTAssertFalse(AppScanner.belongsToApp("org.sparkle-project.Sparkle", identity: identity))
        XCTAssertFalse(AppScanner.belongsToApp("com.electron.framework", identity: identity))
    }

    // MARK: - Helpers

    private func writeBundle(at url: URL, plistPath: String, bundleID: String) throws {
        let plistURL = url.appending(path: plistPath)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let plist = ["CFBundleIdentifier": bundleID, "CFBundleName": url.deletingPathExtension().lastPathComponent]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
    }
}
