import XCTest
@testable import MacUninstallCore

/// These tests guard the only code path that can destroy user data.
final class ProtectedPathsTests: XCTestCase {

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func testRefusesFilesystemRootAndTopLevelDirectories() {
        for path in ["/", "/System", "/Applications", "/Library", "/usr", "/etc", "/var", "/Users"] {
            XCTAssertFalse(
                ProtectedPaths.isSafeToRemove(URL(fileURLWithPath: path)),
                "\(path) must never be removable"
            )
        }
    }

    func testRefusesTopLevelUserFolders() {
        for sub in ["", "/Library", "/Documents", "/Desktop", "/Downloads", "/.Trash"] {
            let url = URL(fileURLWithPath: home + sub)
            XCTAssertFalse(ProtectedPaths.isSafeToRemove(url), "\(url.path) must never be removable")
        }
    }

    func testRefusesLibrarySubfolderRootsThemselves() {
        // Removing the container of all app data, rather than one app's entry.
        for sub in ["Application Support", "Caches", "Preferences", "Containers", "Group Containers"] {
            let url = URL(fileURLWithPath: home + "/Library/" + sub)
            XCTAssertFalse(ProtectedPaths.isSafeToRemove(url), "\(url.path) must never be removable")
        }
    }

    func testRefusesIrreplaceableTrees() {
        for path in [
            home + "/Library/Keychains/login.keychain-db",
            home + "/Library/Mobile Documents/com~apple~CloudDocs/thing",
            home + "/Library/CloudStorage/Dropbox/file.txt",
            "/System/Library/CoreServices/Finder.app",
        ] {
            XCTAssertFalse(ProtectedPaths.isSafeToRemove(URL(fileURLWithPath: path)), path)
        }
    }

    func testRefusesPathsOutsideAllowedRoots() {
        for path in [home + "/Documents/report.pdf", "/opt/homebrew/bin/git", "/Volumes/Backup/data"] {
            XCTAssertFalse(ProtectedPaths.isSafeToRemove(URL(fileURLWithPath: path)), path)
        }
    }

    func testAllowsGenuineApplicationLeftovers() {
        for path in [
            home + "/Library/Application Support/com.acme.App",
            home + "/Library/Preferences/com.acme.App.plist",
            home + "/Library/Caches/com.acme.App",
            home + "/Library/Containers/com.acme.App",
            "/Applications/Acme.app",
            "/Library/LaunchDaemons/com.acme.helper.plist",
            "/Library/PrivilegedHelperTools/com.acme.helper",
            "/private/var/db/receipts/com.acme.pkg.bom",
        ] {
            XCTAssertTrue(
                ProtectedPaths.isSafeToRemove(URL(fileURLWithPath: path)),
                "\(path) should be removable"
            )
        }
    }

    func testRefusesTraversalOutOfAllowedRoots() {
        // `standardizedFileURL` resolves `..`, so this lands on /Users and is refused.
        let url = URL(fileURLWithPath: home + "/Library/Application Support/../../../etc/passwd")
        XCTAssertFalse(ProtectedPaths.isSafeToRemove(url))
    }

    func testRefusesSymlinkPointingOutsideAllowedRoots() throws {
        let fm = FileManager.default
        // Build a real symlink inside an allowed root that targets a protected tree.
        let supportDir = URL(fileURLWithPath: home + "/Library/Application Support")
        try XCTSkipUnless(fm.isWritableFile(atPath: supportDir.path), "Application Support not writable")

        let link = supportDir.appending(path: "MacUninstallTestLink-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
        defer { try? fm.removeItem(at: link) }

        XCTAssertFalse(
            ProtectedPaths.isSafeToRemove(link),
            "A symlink escaping to /etc must be refused"
        )
        if case .symlinkEscapesAllowedRoots = ProtectedPaths.rejection(for: link) {} else {
            XCTFail("Expected a symlink rejection, got \(String(describing: ProtectedPaths.rejection(for: link)))")
        }
    }

    func testRejectionExplanationsAreNonEmpty() {
        let rejection = ProtectedPaths.rejection(for: URL(fileURLWithPath: "/System"))
        XCTAssertNotNil(rejection)
        XCTAssertFalse(rejection!.explanation.isEmpty)
    }
}
