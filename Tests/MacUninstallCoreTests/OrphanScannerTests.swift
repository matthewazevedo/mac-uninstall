import XCTest
@testable import MacUninstallCore

/// Finding leftovers with no app behind them means working without the one thing
/// every other rule starts from, so the guard rails are different: only names that
/// identify an app on their own, and nothing an installed app could still own.
final class OrphanScannerTests: XCTestCase {

    private var root: URL!
    private var library: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallOrphans-\(UUID().uuidString)")
        library = root.appending(path: "Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ relativePath: String, isDirectory: Bool = false) throws -> URL {
        let url = library.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("x".utf8).write(to: url)
        }
        return url
    }

    private func scanner(_ folders: [String: LeftoverCategory]) -> OrphanScanner {
        OrphanScanner(
            locations: folders.map { path, category in
                SearchLocation(url: library.appending(path: path), category: category)
            },
            // The temporary tree is nowhere near the real allowed roots, so the
            // production safety check would refuse all of it.
            options: .init(measureSizes: false, safetyCheck: { _ in true })
        )
    }

    private func app(_ bundleID: String) -> AppIdentity {
        AppIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleID).app"),
            bundleID: bundleID,
            displayName: bundleID
        )
    }

    // MARK: - What counts as an orphan

    func testFindsDataWhoseAppIsGoneAndGroupsItByIdentifier() async throws {
        _ = try make("Preferences/com.acme.App.plist")
        _ = try make("Preferences/com.acme.App.helper.plist")
        _ = try make("Application Support/com.acme.App", isDirectory: true)

        let groups = await scanner([
            "Preferences": .preferences, "Application Support": .supportFiles,
        ]).scan(installedApps: [app("com.other.Thing")])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.identifier, "com.acme.App")
        XCTAssertEqual(groups.first?.leftovers.count, 3)
    }

    /// Nothing here was matched against an app; the evidence is the absence of one.
    func testEverythingFoundNeedsAHumanDecision() async throws {
        _ = try make("Preferences/com.acme.App.plist")

        let groups = await scanner(["Preferences": .preferences]).scan(installedApps: [])

        XCTAssertEqual(groups.first?.leftovers.first?.confidence, .possible)
        XCTAssertFalse(groups.first?.leftovers.first?.confidence.selectedByDefault ?? true)
    }

    func testLeavesInstalledAppsAlone() async throws {
        _ = try make("Preferences/com.acme.App.plist")
        _ = try make("Preferences/com.acme.App.helper.plist")

        let groups = await scanner(["Preferences": .preferences])
            .scan(installedApps: [app("com.acme.App")])

        XCTAssertTrue(groups.isEmpty, "An installed app's own data is not an orphan")
    }

    /// com.google.Keystone is Chrome's shared updater, not an orphan, for as long as
    /// any Google app is installed. Missing a real orphan costs a folder that stays;
    /// the other mistake destroys a working app's data.
    func testLeavesAVendorsSharedComponentsAloneWhileAnyOfTheirAppsIsInstalled() async throws {
        _ = try make("Application Support/com.google.Keystone", isDirectory: true)

        let groups = await scanner(["Application Support": .supportFiles])
            .scan(installedApps: [app("com.google.Chrome")])

        XCTAssertTrue(groups.isEmpty)
    }

    /// Group containers are named `<TeamID>.com.acme.shared`, so the identifier that
    /// decides ownership is not at the front of the name.
    func testLeavesAnInstalledAppsGroupContainerAlone() async throws {
        _ = try make("Group Containers/Q6L2SF6YDW.com.acme.shared", isDirectory: true)
        _ = try make("Group Containers/group.com.acme.other", isDirectory: true)

        let groups = await scanner(["Group Containers": .containers])
            .scan(installedApps: [app("com.acme.App")])

        XCTAssertTrue(groups.isEmpty, "Both belong to an installed vendor's namespace")
    }

    /// A `.pkg` receipt's `PackageIdentifier` is Apple's installer namespace, not the
    /// app's own `CFBundleIdentifier` — Tailscale's receipt is `com.tailscale.ipn.macsys`
    /// for an app whose bundle ID is `io.tailscale.ipn.macsys`. No amount of prefix
    /// matching bridges "com" to "io"; only the receipt's own `InstallPrefixPath`
    /// says what it installed.
    func testLeavesAReceiptAloneWhenItsInstallPrefixPathIsStillThere() async throws {
        let receiptPlist = try make("Receipts/com.tailscale.ipn.macsys.plist")
        _ = try make("Receipts/com.tailscale.ipn.macsys.bom")
        let plist: [String: Any] = [
            "InstallPrefixPath": "Applications/Tailscale.app",
            "PackageIdentifier": "com.tailscale.ipn.macsys",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: receiptPlist)

        let tailscale = AppIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Tailscale.app"),
            bundleID: "io.tailscale.ipn.macsys",
            displayName: "Tailscale"
        )

        let groups = await scanner(["Receipts": .receipts]).scan(installedApps: [tailscale])

        XCTAssertTrue(groups.isEmpty, "The app this receipt installed is still there")
    }

    func testIgnoresNamesThatIdentifyNothing() async throws {
        for name in ["Acme", "Updater", "com.acme", "Some File.txt", "logs"] {
            _ = try make("Application Support/\(name)", isDirectory: true)
        }

        let groups = await scanner(["Application Support": .supportFiles]).scan(installedApps: [])

        XCTAssertTrue(
            groups.isEmpty,
            "A folder called Acme could belong to anything, and guessing is not evidence"
        )
    }

    func testNeverAttributesApplesOwnFilesToAMissingApp() async throws {
        _ = try make("Preferences/com.apple.dock.plist")
        _ = try make("Preferences/com.apple.finder.plist")

        let groups = await scanner(["Preferences": .preferences]).scan(installedApps: [])

        XCTAssertTrue(groups.isEmpty, "macOS is not a missing app")
    }

    func testRefusesAnythingTheSafetyCheckRejects() async throws {
        _ = try make("Preferences/com.acme.App.plist")

        let scanner = OrphanScanner(
            locations: [SearchLocation(url: library.appending(path: "Preferences"), category: .preferences)],
            options: .init(measureSizes: false, safetyCheck: { _ in false })
        )

        let groups = await scanner.scan(installedApps: [])
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Grouping rules

    func testIdentifiersAreNormalisedBeforeGrouping() {
        XCTAssertEqual(OrphanScanner.groupIdentifier(for: "com.acme.App.helper"), "com.acme.App")
        XCTAssertEqual(OrphanScanner.groupIdentifier(for: "com.acme.App"), "com.acme.App")
        XCTAssertEqual(
            OrphanScanner.groupIdentifier(for: "Q6L2SF6YDW.com.acme.shared.data"),
            "com.acme.shared"
        )
        XCTAssertTrue(OrphanScanner.isTeamIdentifier("Q6L2SF6YDW"))
        XCTAssertFalse(OrphanScanner.isTeamIdentifier("com"))
    }

    func testBiggestGroupsComeFirst() {
        let groups = OrphanScanner.grouped([
            Leftover(
                url: URL(fileURLWithPath: "/Library/Caches/com.small.App"),
                category: .caches, confidence: .possible, reason: "", sizeBytes: 10
            ),
            Leftover(
                url: URL(fileURLWithPath: "/Library/Caches/com.large.App"),
                category: .caches, confidence: .possible, reason: "", sizeBytes: 5_000
            ),
        ])

        XCTAssertEqual(groups.map(\.identifier), ["com.large.App", "com.small.App"])
    }
}
