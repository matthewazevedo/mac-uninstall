import XCTest
@testable import MacUninstallCore

/// Records scripts instead of running them, so tests never elevate or delete.
final class SpyPrivilegedExecutor: PrivilegedExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    var scripts: [String] { lock.withLock { _scripts } }

    var errorToThrow: Error?

    func run(script: String) async throws {
        lock.withLock { _scripts.append(script) }
        if let errorToThrow { throw errorToThrow }
    }
}

final class RemoverTests: XCTestCase {

    private func leftover(_ path: String, admin: Bool = false, category: LeftoverCategory = .supportFiles) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: path),
            category: category,
            confidence: .certain,
            reason: "test",
            requiresAdmin: admin
        )
    }

    /// Even if a protected path reaches the plan, the remover must refuse it.
    /// This is the guarantee that a scanner bug cannot destroy the system.
    func testRefusesProtectedPathsRegardlessOfPlan() async {
        let spy = SpyPrivilegedExecutor()
        let remover = Remover(privileged: spy)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let dangerous = [
            leftover("/"),
            leftover("/System"),
            leftover("/Library", admin: true),
            leftover(home),
            leftover(home + "/Documents"),
            leftover(home + "/Library/Keychains/login.keychain-db"),
        ]

        let report = await remover.remove(dangerous)

        XCTAssertEqual(report.failed.count, dangerous.count, "Every protected path must be refused")
        XCTAssertTrue(report.succeeded.isEmpty)
        XCTAssertTrue(spy.scripts.isEmpty, "Nothing should reach the privileged executor")
        for outcome in report.failed {
            XCTAssertTrue(outcome.message?.contains("Refused") == true, outcome.message ?? "")
        }
    }

    /// All privileged items share a single elevation, so the user is prompted once.
    func testPrivilegedItemsAreBatchedIntoOneAuthorizedScript() async {
        let spy = SpyPrivilegedExecutor()
        let remover = Remover(options: .init(unloadLaunchItems: false), privileged: spy)

        let items = [
            leftover("/Library/LaunchDaemons/com.test.fake.plist", admin: true, category: .launchItems),
            leftover("/Library/PrivilegedHelperTools/com.test.fake", admin: true, category: .privilegedHelpers),
        ]

        let report = await remover.remove(items)

        XCTAssertEqual(spy.scripts.count, 1, "One elevation for the whole batch")
        let script = spy.scripts[0]
        XCTAssertTrue(script.contains("/Library/LaunchDaemons/com.test.fake.plist"))
        XCTAssertTrue(script.contains("/Library/PrivilegedHelperTools/com.test.fake"))
        XCTAssertTrue(script.contains("MANIFEST.txt"), "A manifest makes the move reversible")
        XCTAssertTrue(script.contains("/bin/mv"), "Items are moved, never deleted")
        XCTAssertFalse(script.contains("rm -rf"), "Privileged removal must never hard-delete")
        XCTAssertTrue(report.isFullSuccess)
        XCTAssertNotNil(report.quarantineDirectory)
    }

    func testPathsWithQuotesAreEscapedInTheGeneratedScript() async {
        let spy = SpyPrivilegedExecutor()
        let remover = Remover(options: .init(unloadLaunchItems: false), privileged: spy)

        // A single quote in a filename must not break out of the shell string.
        _ = await remover.remove([
            leftover("/Library/Application Support/it's a trap'; rm -rf /", admin: true)
        ])

        let script = spy.scripts.first ?? ""
        XCTAssertFalse(script.contains("; rm -rf /\n"), "Quoting must neutralise injected commands")
        XCTAssertTrue(script.contains("'\\''"), "Single quotes should be shell-escaped")
    }

    func testAuthorizationFailureIsReportedPerItem() async {
        let spy = SpyPrivilegedExecutor()
        spy.errorToThrow = RemovalError.authorizationCancelled
        let remover = Remover(options: .init(unloadLaunchItems: false), privileged: spy)

        let report = await remover.remove([
            leftover("/Library/LaunchDaemons/com.test.fake.plist", admin: true, category: .launchItems)
        ])

        XCTAssertFalse(report.isFullSuccess)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(report.failed[0].message?.contains("cancelled") == true)
    }

    /// Trashing is verified against a real file so the reversible path is exercised.
    func testUserOwnedItemGoesToTheTrashRatherThanBeingDeleted() async throws {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        try XCTSkipUnless(fm.isWritableFile(atPath: support.path), "Application Support not writable")

        let victim = support.appending(path: "MacUninstallTest-\(UUID().uuidString)")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)

        let report = await Remover(privileged: SpyPrivilegedExecutor())
            .remove([leftover(victim.path)])

        XCTAssertTrue(report.isFullSuccess, report.failed.first?.message ?? "")
        XCTAssertFalse(fm.fileExists(atPath: victim.path), "Item should have left its original location")
        XCTAssertEqual(report.succeeded.first?.message, "Moved to Trash.")

        // Clean up whatever landed in the Trash.
        let trashed = fm.homeDirectoryForCurrentUser
            .appending(path: ".Trash/\(victim.lastPathComponent)")
        try? fm.removeItem(at: trashed)
    }
}
