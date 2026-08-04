import XCTest
@testable import MacUninstallCore

/// Regressions from a real removal: an ordinary app in /Applications was quarantined
/// instead of trashed, and landed in a root-owned folder the user could not open.
final class RemovalRoutingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallRouting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Removing an item needs write permission on its parent, not on the item. A
    /// read-only app bundle in a writable /Applications is still an ordinary removal.
    func testReadOnlyBundleInAWritableFolderDoesNotNeedAdmin() async throws {
        let apps = root.appending(path: "Applications")
        let bundle = apps.appending(path: "Birdo.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        // Read-only bundle, writable parent — exactly the case that misrouted.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path) }

        try XCTSkipIf(getuid() == 0, "Permission bits do not apply as root")

        let identity = AppIdentity(bundleURL: bundle, bundleID: "com.acme.birdo", displayName: "Birdo")
        let result = await LeftoverScanner(
            locations: [], options: .init(measureSizes: false, safetyCheck: { _ in true })
        ).scan(for: identity)

        let bundleItem = try XCTUnwrap(result.leftovers.first { $0.category == .application })
        XCTAssertFalse(
            bundleItem.requiresAdmin,
            "A writable parent means this is an ordinary removal, not a privileged one"
        )
    }

    /// The Trash is where people expect their files, and Put Back only works there.
    func testOrdinaryItemsGoToTheTrashRatherThanQuarantine() async throws {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        try XCTSkipUnless(fm.isWritableFile(atPath: support.path), "Application Support not writable")

        let victim = support.appending(path: "MacUninstallRoutingTest-\(UUID().uuidString)")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)

        let spy = SpyPrivilegedExecutor()
        let report = await Remover(privileged: spy).remove([
            Leftover(url: victim, category: .supportFiles, confidence: .certain, reason: "test")
        ])

        XCTAssertTrue(report.isFullSuccess, report.failed.first?.message ?? "")
        XCTAssertEqual(report.succeeded.first?.message, "Moved to Trash.")
        XCTAssertTrue(spy.quarantineCalls.isEmpty, "Nothing trashable should reach quarantine")

        try? fm.removeItem(
            at: fm.homeDirectoryForCurrentUser.appending(path: ".Trash/\(victim.lastPathComponent)")
        )
    }

    /// The case that sent Birdo to quarantine: plenty of installers ship read-only
    /// bundles, and those must still end up in the Trash rather than in a folder the
    /// user has to be told about.
    func testAReadOnlyBundleStillReachesTheTrash() async throws {
        let fm = FileManager.default
        try XCTSkipUnless(fm.isWritableFile(atPath: "/Applications"), "/Applications not writable")
        try XCTSkipIf(getuid() == 0, "Permission bits do not apply as root")

        let bundle = URL(fileURLWithPath: "/Applications/ZZReadOnlyProbe-\(UUID().uuidString).app")
        try fm.createDirectory(at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.path)
        XCTAssertFalse(fm.isWritableFile(atPath: bundle.path))

        let spy = SpyPrivilegedExecutor()
        let report = await Remover(privileged: spy).remove([
            Leftover(url: bundle, category: .application, confidence: .certain, reason: "test")
        ])

        XCTAssertTrue(report.isFullSuccess, report.failed.first?.message ?? "")
        XCTAssertEqual(report.succeeded.first?.message, "Moved to Trash.")
        XCTAssertTrue(spy.quarantineCalls.isEmpty, "A read-only bundle must not be quarantined")

        try? fm.removeItem(
            at: fm.homeDirectoryForCurrentUser.appending(path: ".Trash/\(bundle.lastPathComponent)")
        )
        try? fm.removeItem(at: bundle)
    }

    /// A failed trash must not simply be reported as a failure — it escalates, so the
    /// item is still dealt with rather than left behind.
    func testAnItemThatCannotBeTrashedEscalatesToQuarantine() async {
        let spy = SpyPrivilegedExecutor()
        // Not present on disk, so trashItem fails.
        let missing = URL(fileURLWithPath: "/Applications/DefinitelyNotInstalled-\(UUID().uuidString).app")

        _ = await Remover(options: .init(unloadLaunchItems: false), privileged: spy).remove([
            Leftover(url: missing, category: .application, confidence: .certain, reason: "test")
        ])

        XCTAssertEqual(spy.quarantineCalls.count, 1, "A failed trash should escalate")
        XCTAssertEqual(spy.quarantineCalls.first?.items.first, missing)
    }
}
