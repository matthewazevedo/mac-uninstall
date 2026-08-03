import XCTest
@testable import MacUninstallCore

/// Exercises the scanner end to end against a synthetic Library tree.
final class LeftoverScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture helpers

    private func makeDir(_ relative: String) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    /// The scanner's path filter is bypassed here because the fixture lives in a
    /// temporary directory rather than a real Library folder.
    private func scanner(_ locations: [SearchLocation]) -> LeftoverScanner {
        LeftoverScanner(
            locations: locations,
            options: .init(measureSizes: false, safetyCheck: { _ in true })
        )
    }

    private func identity(bundleURL: URL) -> AppIdentity {
        AppIdentity(
            bundleURL: bundleURL,
            bundleID: "com.acmesoft.Sketchpad",
            displayName: "Sketchpad",
            executableName: "Sketchpad",
            teamID: "AB12CD34EF",
            signingOrganization: "AcmeSoft Inc.",
            helperBundleIDs: ["com.acmesoft.Sketchpad.Updater"]
        )
    }

    // MARK: - Tests

    func testFindsLeftoversAcrossCategoriesAndScoresThem() async throws {
        let support = try makeDir("Library/Application Support")
        let prefs = try makeDir("Library/Preferences")
        let daemons = try makeDir("Library/LaunchDaemons")
        let bundle = try makeDir("Applications/Sketchpad.app")

        try makeFile("Library/Application Support/com.acmesoft.Sketchpad/data.db")
        try makeFile("Library/Preferences/com.acmesoft.Sketchpad.plist")
        try makeFile("Library/Preferences/com.acmesoft.SharedUpdater.plist")
        try makeFile("Library/LaunchDaemons/com.acmesoft.Sketchpad.Updater.plist")
        // Must be ignored entirely.
        try makeFile("Library/Preferences/com.apple.finder.plist")
        try makeFile("Library/Preferences/com.unrelated.Other.plist")

        let result = await scanner([
            .init(url: support, category: .supportFiles, childrenOnly: false),
            .init(url: prefs, category: .preferences),
            .init(url: daemons, category: .launchItems, requiresAdmin: true),
        ]).scan(for: identity(bundleURL: bundle))

        let names = Set(result.leftovers.map(\.url.lastPathComponent))
        XCTAssertTrue(names.contains("com.acmesoft.Sketchpad"))
        XCTAssertTrue(names.contains("com.acmesoft.Sketchpad.plist"))
        XCTAssertTrue(names.contains("com.acmesoft.Sketchpad.Updater.plist"))
        XCTAssertTrue(names.contains("Sketchpad.app"), "The bundle itself must be included")

        XCTAssertFalse(names.contains("com.apple.finder.plist"), "Apple files must never be claimed")
        XCTAssertFalse(names.contains("com.unrelated.Other.plist"))

        // The vendor's shared updater is found, but only as a lower-confidence hit.
        let shared = result.leftovers.first { $0.url.lastPathComponent == "com.acmesoft.SharedUpdater.plist" }
        XCTAssertEqual(shared?.confidence, .likely)

        let daemon = result.leftovers.first { $0.category == .launchItems }
        XCTAssertEqual(daemon?.requiresAdmin, true)
    }

    /// The central safety behaviour: uninstalling one product must not propose
    /// deleting a shared vendor folder that holds another product's data.
    func testProposesVendorSubfolderRatherThanWholeVendorFolder() async throws {
        let support = try makeDir("Library/Application Support")
        try makeFile("Library/Application Support/AcmeSoft/Sketchpad/cache.bin")
        try makeFile("Library/Application Support/AcmeSoft/OtherProduct/important.db")

        let result = await scanner([
            .init(url: support, category: .supportFiles, childrenOnly: false)
        ]).scan(for: identity(bundleURL: root.appending(path: "Applications/Nope.app")))

        let paths = result.leftovers.map(\.url.lastPathComponent)
        XCTAssertTrue(paths.contains("Sketchpad"), "The app's own subfolder should be found")
        XCTAssertFalse(
            paths.contains("OtherProduct"),
            "Another product's folder must never be proposed"
        )

        // If the vendor folder itself is listed at all, it must be low confidence
        // so it is never removed without an explicit decision.
        if let vendor = result.leftovers.first(where: { $0.url.lastPathComponent == "AcmeSoft" }) {
            XCTAssertEqual(vendor.confidence, .possible)
            XCTAssertFalse(vendor.confidence.selectedByDefault)
        }
    }

    /// Catches Electron/ToDesktop-style leftovers whose filename encodes nothing.
    func testDeepInspectionFindsOpaquelyNamedPreferences() async throws {
        let prefs = try makeDir("Library/Preferences")
        try makeFile(
            "Library/Preferences/com.todesktop.230313mzl4w4u92.plist",
            contents: "<plist><string>com.acmesoft.Sketchpad</string></plist>"
        )
        try makeFile(
            "Library/Preferences/com.todesktop.unrelated.plist",
            contents: "<plist><string>com.someoneelse.App</string></plist>"
        )

        let result = await scanner([.init(url: prefs, category: .preferences)])
            .scan(for: identity(bundleURL: root.appending(path: "Applications/Nope.app")))

        let names = Set(result.leftovers.map(\.url.lastPathComponent))
        XCTAssertTrue(
            names.contains("com.todesktop.230313mzl4w4u92.plist"),
            "Content-based evidence should find opaquely named files"
        )
        XCTAssertFalse(names.contains("com.todesktop.unrelated.plist"))
    }

    func testDeepInspectionCanBeDisabled() async throws {
        let prefs = try makeDir("Library/Preferences")
        try makeFile(
            "Library/Preferences/opaque.plist",
            contents: "<plist><string>com.acmesoft.Sketchpad</string></plist>"
        )

        let scanner = LeftoverScanner(
            locations: [.init(url: prefs, category: .preferences)],
            options: .init(deepInspectPlists: false, measureSizes: false, safetyCheck: { _ in true })
        )
        let result = await scanner.scan(for: identity(bundleURL: root.appending(path: "Applications/Nope.app")))
        XCTAssertTrue(result.leftovers.isEmpty)
    }

    func testDefaultSelectionCoversOnlyCertainMatches() async throws {
        let prefs = try makeDir("Library/Preferences")
        try makeFile("Library/Preferences/com.acmesoft.Sketchpad.plist")
        try makeFile("Library/Preferences/com.acmesoft.SharedUpdater.plist")

        let result = await scanner([.init(url: prefs, category: .preferences)])
            .scan(for: identity(bundleURL: root.appending(path: "Applications/Nope.app")))

        let autoSelected = result.leftovers.filter { $0.confidence.selectedByDefault }
        XCTAssertEqual(autoSelected.count, 1)
        XCTAssertEqual(autoSelected.first?.url.lastPathComponent, "com.acmesoft.Sketchpad.plist")
    }

    func testMissingLocationsAreNotReportedAsInaccessible() async throws {
        let missing = root.appending(path: "Library/DoesNotExist")
        let result = await scanner([.init(url: missing, category: .caches)])
            .scan(for: identity(bundleURL: root.appending(path: "Applications/Nope.app")))
        XCTAssertFalse(result.isIncomplete, "A folder that does not exist is not an access failure")
    }

    func testUnreadableLocationMarksResultIncomplete() async throws {
        let locked = try makeDir("Library/Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        // Running as root would defeat the permission bits and invalidate the test.
        try XCTSkipIf(getuid() == 0, "Cannot test unreadable directories as root")

        let result = await scanner([.init(url: locked, category: .caches)])
            .scan(for: identity(bundleURL: root.appending(path: "Applications/Nope.app")))

        XCTAssertTrue(result.isIncomplete)
        XCTAssertEqual(result.inaccessibleLocations.count, 1)
    }
}
