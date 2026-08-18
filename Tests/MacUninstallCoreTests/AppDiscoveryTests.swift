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

    /// Catalyst and "Designed for iPad" apps put `Info.plist` directly inside
    /// `Wrapper/<name>.app`, not under `Contents/`, and a `WrappedBundle` symlink at
    /// the bundle root points there — that symlink, not the folder name, is what
    /// `Bundle(url:)` actually follows to find it.
    @discardableResult
    private func makeWrappedApp(_ relative: String, bundleID: String) throws -> URL {
        let outer = root.appending(path: relative)
        let name = outer.deletingPathExtension().lastPathComponent
        let inner = outer.appending(path: "Wrapper/\(name).app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: inner.appending(path: "Info.plist"))
        try FileManager.default.createSymbolicLink(
            atPath: outer.appending(path: "WrappedBundle").path,
            withDestinationPath: "Wrapper/\(name).app"
        )
        return outer
    }

    /// IVPN's privileged helper is a real case: its bundle ID (`net.ivpn.client.Helper`)
    /// shares no namespace with the app that owns it (`com.electron.ivpn-ui`) because
    /// it's actually installed by a nested installer app (`IVPN Installer.app`, itself
    /// `net.ivpn.client.installer`) sitting in `Contents/MacOS/`. Vendor-prefix
    /// matching can never connect these three identifiers — only the installer's own
    /// `SMPrivilegedExecutables` declaration says the helper belongs to this app.
    func testCollectsAPrivilegedHelperDeclaredByANestedInstaller() throws {
        let app = try makeApp("IVPN.app", bundleID: "com.electron.ivpn-ui")
        let installerPlist = app.appending(path: "Contents/MacOS/IVPN Installer.app/Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: installerPlist.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "net.ivpn.client.installer",
            "SMPrivilegedExecutables": ["net.ivpn.client.Helper": "identifier net.ivpn.client.Helper"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: installerPlist)

        let identity = AppScanner().readIdentity(at: app)
        XCTAssertTrue(identity?.helperBundleIDs.contains("net.ivpn.client.Helper") ?? false)
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

    /// RidePack and Birdo ship this way: `Info.plist` lives at
    /// `Foo.app/Wrapper/Foo.app/Info.plist`, not `Foo.app/Contents/Info.plist`. A
    /// hardcoded `Contents/Info.plist` read leaves `bundleID` nil, which then makes
    /// the app invisible to both the orphan scan (it looks removed) and its own
    /// container match (`~/Library/Containers/<bundle id>` is never found).
    func testReadsIdentityFromAWrappedCatalystBundle() throws {
        let app = try makeWrappedApp("RidePack.app", bundleID: "com.ridepack.app")

        let identity = AppScanner().readIdentity(at: app)
        XCTAssertEqual(identity?.bundleID, "com.ridepack.app")
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
