import XCTest
@testable import MacUninstallCore

/// Regressions for apps the scanner used to miss entirely.
final class AppDiscoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallDiscovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeApp(_ relative: String, bundleID: String) throws -> URL {
        let url = root.appending(path: relative)
        let plistURL = url.appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": url.deletingPathExtension().lastPathComponent,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
        return url
    }

    private func names(_ roots: [AppScanner.SearchRoot]) -> Set<String> {
        Set(AppScanner().installedApps(in: roots).map(\.displayName))
    }

    /// The bug that started this: macOS marks /Applications/Safari.app hidden because
    /// it is a symlink into the Safari cryptex, so `.skipsHiddenFiles` dropped it.
    func testFindsAppsMarkedHidden() throws {
        let app = try makeApp("Hidden.app", bundleID: "com.acme.hidden")
        var values = URLResourceValues()
        values.isHidden = true
        var url = app
        try url.setResourceValues(values)

        XCTAssertTrue(
            names([.init(root)]).contains("Hidden"),
            "An app flagged hidden is still an installed app"
        )
    }

    /// Vendors group products into folders; those apps are installed just the same.
    func testFindsAppsNestedInsideVendorFolders() throws {
        try makeApp("TopLevel.app", bundleID: "com.acme.top")
        try makeApp("VendorFolder/Nested.app", bundleID: "com.acme.nested")
        try makeApp("VendorFolder/Deeper/Deepest.app", bundleID: "com.acme.deepest")

        let found = names([.init(root, depth: 2)])
        XCTAssertTrue(found.contains("TopLevel"))
        XCTAssertTrue(found.contains("Nested"))
        XCTAssertTrue(found.contains("Deepest"))
    }

    func testDepthLimitIsRespected() throws {
        try makeApp("A/B/C/TooDeep.app", bundleID: "com.acme.deep")
        XCTAssertFalse(names([.init(root, depth: 1)]).contains("TooDeep"))
        XCTAssertTrue(names([.init(root, depth: 3)]).contains("TooDeep"))
    }

    /// A flat root must not descend, or scanning /System would walk the whole tree.
    func testFlatRootDoesNotDescend() throws {
        try makeApp("Sub/Nested.app", bundleID: "com.acme.nested")
        XCTAssertTrue(names([.init(root)]).isEmpty)
    }

    func testDotDirectoriesAreIgnored() throws {
        try makeApp(".hiddenfolder/Sneaky.app", bundleID: "com.acme.sneaky")
        XCTAssertFalse(names([.init(root, depth: 2)]).contains("Sneaky"))
    }

    func testTheSameAppIsNotListedTwiceAcrossOverlappingRoots() throws {
        try makeApp("Utilities/Shared.app", bundleID: "com.acme.shared")
        let apps = AppScanner().installedApps(in: [
            .init(root, depth: 2),
            .init(root.appending(path: "Utilities"), depth: 1),
        ])
        XCTAssertEqual(apps.filter { $0.displayName == "Shared" }.count, 1)
    }

    // MARK: - Removability

    /// Apple's apps are listed so the sidebar matches Finder, but must never be
    /// offered for removal.
    func testSystemAppsAreReportedAsNotRemovable() {
        for path in [
            "/System/Applications/Mail.app",
            "/System/Applications/Utilities/Terminal.app",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
        ] {
            let identity = AppIdentity(bundleURL: URL(fileURLWithPath: path), displayName: "X")
            XCTAssertFalse(identity.isRemovable, "\(path) must not be removable")
        }
    }

    func testUserInstalledAppsAreRemovable() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/Applications/Acme.app", home + "/Applications/Acme.app"] {
            let identity = AppIdentity(bundleURL: URL(fileURLWithPath: path), displayName: "Acme")
            XCTAssertTrue(identity.isRemovable, "\(path) should be removable")
        }
    }

    /// A protected bundle must not appear in its own removal plan, or the removal step
    /// is guaranteed to refuse an item the UI already offered.
    func testProtectedBundleIsExcludedFromItsOwnScan() async {
        let identity = AppIdentity(
            bundleURL: URL(fileURLWithPath: "/System/Applications/Mail.app"),
            bundleID: "com.apple.mail",
            displayName: "Mail"
        )
        let result = await LeftoverScanner(
            locations: [], options: .init(measureSizes: false)
        ).scan(for: identity)

        XCTAssertFalse(result.leftovers.contains { $0.category == .application })
    }
}
