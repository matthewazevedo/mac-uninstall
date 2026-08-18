import XCTest
@testable import MacUninstallCore

/// An undo is only as good as the record of where things came from, and a receipt is
/// a file on disk — so putting something back is validated exactly as taking it away
/// was.
final class UndoTests: XCTestCase {

    private func item(
        original: String,
        current: String,
        quarantined: Bool = false
    ) -> RemovalReceipt.Item {
        RemovalReceipt.Item(
            originalPath: original, currentPath: current, wasQuarantined: quarantined
        )
    }

    // MARK: - Receipts

    func testAReportWithNothingRecoverableYieldsNoReceipt() {
        let report = RemovalReport(outcomes: [
            RemovalOutcome(
                url: URL(fileURLWithPath: "/Applications/Acme.app"),
                succeeded: false,
                message: "Could not be moved to the Trash."
            )
        ])
        XCTAssertNil(
            RemovalReceipt(report: report, appName: "Acme"),
            "An undo that cannot restore anything must not be offered"
        )
    }

    func testAReceiptRecordsWhereEachItemActuallyLanded() throws {
        let report = RemovalReport(outcomes: [
            RemovalOutcome(
                url: URL(fileURLWithPath: "/Applications/Acme.app"),
                succeeded: true,
                message: "Moved to Trash.",
                // Finder renames on a collision, which is exactly why the destination
                // is recorded rather than assumed.
                currentLocation: URL(fileURLWithPath: "/Users/someone/.Trash/Acme 2.app")
            ),
            RemovalOutcome(
                url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.acme.plist"),
                succeeded: true,
                message: "Moved to quarantine.",
                currentLocation: URL(fileURLWithPath: "/Users/someone/Library/Application Support/MacUninstall/Quarantine/x/com.acme.plist"),
                wasQuarantined: true
            ),
            RemovalOutcome(url: URL(fileURLWithPath: "/Library/Caches/Acme"), succeeded: false),
        ])

        let receipt = try XCTUnwrap(RemovalReceipt(report: report, appName: "Acme"))

        XCTAssertEqual(receipt.items.count, 2, "Only what moved somewhere recoverable")
        XCTAssertEqual(receipt.items[0].currentPath, "/Users/someone/.Trash/Acme 2.app")
        XCTAssertTrue(receipt.items[1].wasQuarantined)
    }

    func testTheStoreReturnsTheNewestFirstAndDropsTheOldest() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallReceipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReceiptStore(directory: directory)

        for index in 0..<(ReceiptStore.keepCount + 3) {
            try store.save(RemovalReceipt(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                appName: "App \(index)",
                items: [item(original: "/Applications/App.app", current: "/somewhere")]
            ))
        }

        let all = store.all()
        XCTAssertEqual(all.count, ReceiptStore.keepCount)
        XCTAssertEqual(all.first?.appName, "App \(ReceiptStore.keepCount + 2)")
    }

    /// Emptying the Trash makes a receipt useless, and an undo button that cannot work
    /// is worse than no undo button.
    func testAReceiptWhoseFilesAreGoneIsNotOffered() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallReceipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReceiptStore(directory: directory)

        let survivor = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallSurvivor-\(UUID().uuidString)")
        try Data("x".utf8).write(to: survivor)
        defer { try? FileManager.default.removeItem(at: survivor) }

        try store.save(RemovalReceipt(
            date: Date(timeIntervalSince1970: 1),
            appName: "Still there",
            items: [item(original: "/Applications/A.app", current: survivor.path)]
        ))
        try store.save(RemovalReceipt(
            date: Date(timeIntervalSince1970: 2),
            appName: "Emptied",
            items: [item(original: "/Applications/B.app", current: "/nowhere/at/all")]
        ))

        XCTAssertEqual(store.all().first?.appName, "Emptied", "Newest first")
        XCTAssertEqual(store.latestRestorable()?.appName, "Still there")
    }

    // MARK: - Restoring

    /// A receipt is an ordinary file, so a tampered or stale one must not be able to
    /// direct a privileged move at the system.
    func testRestoreRefusesADestinationOutsideTheAllowedRoots() async {
        let spy = SpyPrivilegedExecutor()
        let report = await Remover(privileged: spy).restore(RemovalReceipt(
            appName: "Acme",
            items: [
                item(original: "/etc/sudoers", current: "/tmp/whatever", quarantined: true),
                item(original: "/System/Library/LaunchDaemons/com.apple.x.plist", current: "/tmp/x"),
            ]
        ))

        XCTAssertEqual(report.failed.count, 2)
        XCTAssertTrue(report.succeeded.isEmpty)
        XCTAssertTrue(spy.restoreCalls.isEmpty, "Nothing refused should reach the helper")
        for outcome in report.failed {
            XCTAssertTrue(outcome.message?.contains("Refused") == true, outcome.message ?? "")
        }
    }

    func testRestoreWillNotOverwriteSomethingThatCameBack() async throws {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        try XCTSkipUnless(fm.isWritableFile(atPath: support.path), "Application Support not writable")

        let occupied = support.appending(path: "MacUninstallUndoTest-\(UUID().uuidString)")
        try fm.createDirectory(at: occupied, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: occupied) }

        let staged = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallStaged-\(UUID().uuidString)")
        try Data("x".utf8).write(to: staged)
        defer { try? fm.removeItem(at: staged) }

        let report = await Remover(privileged: SpyPrivilegedExecutor()).restore(RemovalReceipt(
            appName: "Acme",
            items: [item(original: occupied.path, current: staged.path)]
        ))

        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(report.failed[0].message?.contains("already") == true, report.failed[0].message ?? "")
        XCTAssertTrue(fm.fileExists(atPath: staged.path), "The staged copy is left alone")
    }

    /// The whole loop against the real Trash: remove, then put it back where it was.
    func testATrashedItemCanBePutBack() async throws {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        try XCTSkipUnless(fm.isWritableFile(atPath: support.path), "Application Support not writable")

        let victim = support.appending(path: "MacUninstallUndoTest-\(UUID().uuidString)")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)

        let remover = Remover(options: .init(unloadLaunchItems: false), privileged: SpyPrivilegedExecutor())
        let report = await remover.remove([
            Leftover(url: victim, category: .supportFiles, confidence: .certain, reason: "test")
        ])
        XCTAssertTrue(report.isFullSuccess, report.failed.first?.message ?? "")
        XCTAssertFalse(fm.fileExists(atPath: victim.path))

        let receipt = try XCTUnwrap(RemovalReceipt(report: report, appName: "Test"))
        let restored = await remover.restore(receipt)

        XCTAssertTrue(restored.isFullSuccess, restored.failed.first?.message ?? "")
        XCTAssertTrue(fm.fileExists(atPath: victim.path), "It should be back where it started")
        try? fm.removeItem(at: victim)
    }

    func testQuarantinedItemsAreRestoredThroughThePrivilegedPath() async throws {
        let fm = FileManager.default
        let staged = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallStaged-\(UUID().uuidString)")
        try Data("x".utf8).write(to: staged)
        defer { try? fm.removeItem(at: staged) }

        let original = fm.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacUninstallUndoTarget-\(UUID().uuidString)")

        let spy = SpyPrivilegedExecutor()
        let report = await Remover(privileged: spy).restore(RemovalReceipt(
            appName: "Acme",
            items: [item(original: original.path, current: staged.path, quarantined: true)]
        ))

        XCTAssertEqual(spy.restoreCalls.count, 1, "One batch, so one prompt at most")
        XCTAssertEqual(spy.restoreCalls.first?.first?.originalPath, original.path)
        XCTAssertEqual(spy.restoreCalls.first?.first?.quarantinedPath, staged.path)
        XCTAssertTrue(report.isFullSuccess)
    }
}
