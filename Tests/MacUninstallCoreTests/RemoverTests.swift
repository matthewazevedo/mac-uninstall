import XCTest
@testable import MacUninstallCore

/// Records requests instead of performing them, so tests never elevate or delete.
final class SpyPrivilegedExecutor: PrivilegedExecutor, @unchecked Sendable {
    struct QuarantineCall: Sendable {
        var items: [URL]
        var directory: URL
    }

    private let lock = NSLock()
    private var _quarantineCalls: [QuarantineCall] = []
    private var _bootouts: [(label: String, isDaemon: Bool)] = []

    var quarantineCalls: [QuarantineCall] { lock.withLock { _quarantineCalls } }
    var bootouts: [(label: String, isDaemon: Bool)] { lock.withLock { _bootouts } }

    var errorToThrow: Error?
    var failuresToReturn: [String: String] = [:]

    func quarantine(items: [URL], into directory: URL) async throws -> [String: String] {
        lock.withLock { _quarantineCalls.append(QuarantineCall(items: items, directory: directory)) }
        if let errorToThrow { throw errorToThrow }
        return failuresToReturn
    }

    func bootout(label: String, isDaemon: Bool) async throws {
        lock.withLock { _bootouts.append((label, isDaemon)) }
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
        XCTAssertTrue(spy.quarantineCalls.isEmpty, "Nothing should reach the privileged executor")
        for outcome in report.failed {
            XCTAssertTrue(outcome.message?.contains("Refused") == true, outcome.message ?? "")
        }
    }

    /// All privileged items travel in one request, so the user is prompted at most once.
    func testPrivilegedItemsAreBatchedIntoASingleRequest() async {
        let spy = SpyPrivilegedExecutor()
        let remover = Remover(options: .init(unloadLaunchItems: false), privileged: spy)

        let items = [
            leftover("/Library/LaunchDaemons/com.test.fake.plist", admin: true, category: .launchItems),
            leftover("/Library/PrivilegedHelperTools/com.test.fake", admin: true, category: .privilegedHelpers),
        ]

        let report = await remover.remove(items)

        XCTAssertEqual(spy.quarantineCalls.count, 1, "One request for the whole batch")
        let call = spy.quarantineCalls[0]
        XCTAssertEqual(Set(call.items.map(\.path)), Set(items.map(\.url.path)))
        XCTAssertTrue(
            call.directory.path.contains("MacUninstall/Quarantine"),
            "Items are staged for recovery, never deleted"
        )
        XCTAssertTrue(report.isFullSuccess)
        XCTAssertNotNil(report.quarantineDirectory)
    }

    func testPerItemFailuresFromTheHelperAreReportedIndividually() async {
        let spy = SpyPrivilegedExecutor()
        spy.failuresToReturn = ["/Library/LaunchDaemons/com.test.fake.plist": "Refused by the helper."]
        let remover = Remover(options: .init(unloadLaunchItems: false), privileged: spy)

        let report = await remover.remove([
            leftover("/Library/LaunchDaemons/com.test.fake.plist", admin: true, category: .launchItems),
            leftover("/Library/PrivilegedHelperTools/com.test.fake", admin: true, category: .privilegedHelpers),
        ])

        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(report.succeeded.count, 1)
        XCTAssertTrue(report.failed[0].message?.contains("Refused by the helper") == true)
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

    /// Launch daemons must be unloaded before their plists go, or the job keeps
    /// running and can recreate the files just removed.
    func testSystemLaunchDaemonsAreUnloadedBeforeRemoval() async {
        let spy = SpyPrivilegedExecutor()
        let remover = Remover(privileged: spy)

        _ = await remover.remove([
            leftover("/Library/LaunchDaemons/com.test.daemon.plist", admin: true, category: .launchItems)
        ])

        XCTAssertEqual(spy.bootouts.count, 1)
        XCTAssertEqual(spy.bootouts[0].label, "com.test.daemon")
        XCTAssertTrue(spy.bootouts[0].isDaemon)
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

        let trashed = fm.homeDirectoryForCurrentUser
            .appending(path: ".Trash/\(victim.lastPathComponent)")
        try? fm.removeItem(at: trashed)
    }

    // MARK: - AppleScript fallback

    func testShellQuotingNeutralisesInjectedCommands() {
        let quoted = AppleScriptPrivilegedExecutor.shellQuote("it's a trap'; rm -rf /")
        XCTAssertTrue(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
        XCTAssertTrue(quoted.contains("'\\''"), "Single quotes must be escaped")
        // The dangerous text survives only as literal characters inside the quotes.
        XCTAssertFalse(quoted.contains("; rm -rf /'\n"))
    }
}
