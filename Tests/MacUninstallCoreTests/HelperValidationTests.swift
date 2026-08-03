import XCTest
@testable import MacUninstallCore

/// The daemon runs as root and is reachable over XPC, so these argument checks are
/// the boundary between "move a file with privileges" and "write anywhere as root".
final class HelperValidationTests: XCTestCase {

    // MARK: - Quarantine destination

    func testAcceptsAGenuineQuarantineDirectory() {
        XCTAssertTrue(HelperValidation.isAcceptableQuarantineDirectory(
            "/Users/someone/Library/Application Support/MacUninstall/Quarantine/2026-08-03T12-00-00Z"
        ))
    }

    func testRejectsDestinationsOutsideTheQuarantineArea() {
        for directory in [
            "/",
            "/System/Library",
            "/Library/LaunchDaemons",
            "/tmp/anywhere",
            "/Users/someone/Documents",
            "/Users/someone/Library/Application Support/SomethingElse",
            "/private/etc",
        ] {
            XCTAssertFalse(
                HelperValidation.isAcceptableQuarantineDirectory(directory),
                "\(directory) must be refused as a destination"
            )
        }
    }

    func testRejectsTraversalOutOfTheQuarantineArea() {
        // Escaping the quarantine area would let the caller place root-owned files
        // anywhere on the system.
        XCTAssertFalse(HelperValidation.isAcceptableQuarantineDirectory(
            "/Users/someone/Library/Application Support/MacUninstall/Quarantine/../../../../../../System"
        ))
        XCTAssertFalse(HelperValidation.isAcceptableQuarantineDirectory(
            "/Users/someone/Library/Application Support/MacUninstall/Quarantine/a/../../../../etc"
        ))
    }

    func testRejectsAQuarantineRootWithNoSessionFolder() {
        // The trailing separator is required, so the caller cannot target the root
        // of the quarantine area itself.
        XCTAssertFalse(HelperValidation.isAcceptableQuarantineDirectory(
            "/Users/someone/Library/Application Support/MacUninstall/Quarantine"
        ))
    }

    // MARK: - Launchd labels

    func testAcceptsRealLaunchdLabels() {
        for label in ["com.acme.helper", "io.tailscale.ipn.macsys", "com.acme.App-Updater", "a_b.c"] {
            XCTAssertTrue(HelperValidation.isValidLaunchdLabel(label), label)
        }
    }

    /// The label is concatenated into a launchd domain target, so anything that could
    /// change which domain is addressed has to be refused.
    func testRejectsLabelsThatCouldRedirectTheDomain() {
        for label in [
            "",
            "com.acme/../../system/com.apple.important",
            "system/com.apple.thing",
            "com.acme helper",
            "com.acme;reboot",
            "com.acme\nsystem/other",
            "com.acme$(whoami)",
            "com.acme`id`",
            "..",
            String(repeating: "a", count: 257),
        ] {
            XCTAssertFalse(
                HelperValidation.isValidLaunchdLabel(label),
                "\(label.debugDescription) must be refused"
            )
        }
    }
}
