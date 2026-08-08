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
    private var _restoreCalls: [[RestoreRequest]] = []
    private var _bootouts: [String] = []

    var quarantineCalls: [QuarantineCall] { lock.withLock { _quarantineCalls } }
    var restoreCalls: [[RestoreRequest]] { lock.withLock { _restoreCalls } }
    var bootouts: [String] { lock.withLock { _bootouts } }

    var errorToThrow: Error?
    var failuresToReturn: [String: String] = [:]
    var restoreFailuresToReturn: [String: String] = [:]

    func quarantine(items: [URL], into directory: URL) async throws -> QuarantineResult {
        lock.withLock { _quarantineCalls.append(QuarantineCall(items: items, directory: directory)) }
        if let errorToThrow { throw errorToThrow }
        // Stand in for the real mover, which reports where each item landed.
        let destinations = items.reduce(into: [String: String]()) { result, item in
            guard failuresToReturn[item.path] == nil else { return }
            result[item.path] = directory.appending(path: item.lastPathComponent).path
        }
        return QuarantineResult(failures: failuresToReturn, destinations: destinations)
    }

    func restore(_ items: [RestoreRequest]) async throws -> [String: String] {
        lock.withLock { _restoreCalls.append(items) }
        if let errorToThrow { throw errorToThrow }
        return restoreFailuresToReturn
    }

    func bootoutDaemon(label: String) async throws {
        lock.withLock { _bootouts.append(label) }
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

        XCTAssertEqual(spy.bootouts, ["com.test.daemon"])
    }

    /// A path the remover refuses to touch must not have its job booted out either.
    /// The rejection is the gate everything passes through, not a filter on one step.
    func testRefusedPathsAreNotBootedOut() async {
        let spy = SpyPrivilegedExecutor()
        let remover = Remover(privileged: spy)

        let report = await remover.remove([
            leftover("/Library/LaunchDaemons", admin: true, category: .launchItems)
        ])

        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(spy.bootouts.isEmpty, "Nothing refused should reach launchctl")
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

    private static let fakeQuarantine = URL(
        fileURLWithPath:
            "/Users/someone/Library/Application Support/MacUninstall/Quarantine/2026-08-08T12-00-00Z"
    )

    /// Two items from different folders routinely share a filename. `mv -f` would
    /// destroy the first, in the step whose whole promise is that it is reversible.
    func testFallbackRenamesRatherThanOverwritingOnACollision() {
        let items = [
            URL(fileURLWithPath: "/Library/Preferences/com.acme.App.plist"),
            URL(fileURLWithPath: "/Library/Application Support/Acme/com.acme.App.plist"),
        ]

        let destinations = AppleScriptPrivilegedExecutor.destinations(
            for: items, in: Self.fakeQuarantine
        )

        XCTAssertEqual(destinations.count, 2)
        XCTAssertEqual(Set(destinations.values).count, 2, "Both items must survive")
        for item in items {
            XCTAssertTrue(
                destinations[item.path]?.hasPrefix(Self.fakeQuarantine.path) == true,
                "Everything stays inside the quarantine folder"
            )
        }
    }

    /// Without this the folder belongs to root, inside the user's own Library, and the
    /// promise that quarantined items are recoverable is false for everyone who has not
    /// yet approved the helper.
    func testFallbackHandsTheQuarantineFolderBackToTheUser() {
        let items = [URL(fileURLWithPath: "/Library/LaunchDaemons/com.acme.plist")]
        let script = AppleScriptPrivilegedExecutor.quarantineScript(
            items: items,
            into: Self.fakeQuarantine,
            destinations: AppleScriptPrivilegedExecutor.destinations(for: items, in: Self.fakeQuarantine)
        )

        XCTAssertTrue(script.contains("/usr/sbin/chown -R \(getuid()):\(getgid())"), script)
        XCTAssertTrue(
            script.contains("'/Users/someone/Library/Application Support/MacUninstall'"),
            "Ownership is repaired from the top of the app's own area down"
        )
    }

    /// One failed move must not abandon the items after it, and the caller has to be
    /// told which ones did not make it.
    func testFallbackReportsPerItemFailuresRatherThanAbortingTheBatch() {
        let items = [
            URL(fileURLWithPath: "/Library/LaunchDaemons/com.acme.one.plist"),
            URL(fileURLWithPath: "/Library/LaunchDaemons/com.acme.two.plist"),
        ]
        let script = AppleScriptPrivilegedExecutor.quarantineScript(
            items: items,
            into: Self.fakeQuarantine,
            destinations: AppleScriptPrivilegedExecutor.destinations(for: items, in: Self.fakeQuarantine)
        )

        // Every move is guarded, so `set -e` cannot end the run at the first failure.
        XCTAssertEqual(script.components(separatedBy: "if /bin/mv").count - 1, items.count)
        XCTAssertTrue(script.contains("\(AppleScriptPrivilegedExecutor.failureMarker) 0"))
        XCTAssertTrue(script.contains("\(AppleScriptPrivilegedExecutor.failureMarker) 1"))

        let failed = AppleScriptPrivilegedExecutor.failedIndices(
            in: "\(AppleScriptPrivilegedExecutor.failureMarker) 1\n"
        )
        XCTAssertEqual(failed, [1])
    }

    /// A restore must not overwrite: the app may have been reinstalled since.
    func testRestoreScriptRefusesToOverwriteAndPutsOwnershipBack() {
        let script = AppleScriptPrivilegedExecutor.restoreScript([
            RestoreRequest(
                quarantinedPath: Self.fakeQuarantine.appending(path: "com.acme.plist").path,
                originalPath: "/Library/LaunchDaemons/com.acme.plist"
            )
        ])

        XCTAssertTrue(script.contains("if [ -e '/Library/LaunchDaemons/com.acme.plist' ]"), script)
        // A user-writable launch daemon is a privilege escalation, so a system
        // location gets root:wheel back rather than the user who owned the copy in
        // quarantine.
        XCTAssertEqual(AppleScriptPrivilegedExecutor.ownerSpec(for: "/Library/LaunchDaemons/x"), "0:0")
        XCTAssertEqual(
            AppleScriptPrivilegedExecutor.ownerSpec(for: "/Users/someone/Library/Caches/x"),
            "\(getuid()):\(getgid())"
        )
    }
}
