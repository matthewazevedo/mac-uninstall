import XCTest
@testable import MacUninstallCore

/// A vendor's apps share group containers. Removing one app must never take a
/// container another installed app is entitled to.
final class SharedContainersTests: XCTestCase {

    private func leftover(_ path: String, _ category: LeftoverCategory = .containers) -> Leftover {
        Leftover(url: URL(fileURLWithPath: path), category: category,
                 confidence: .likely, reason: "")
    }

    /// Scanning 1Password for Safari matched 1Password's container by team ID.
    func testDropsAContainerAnotherInstalledAppUses() {
        let found = [
            leftover("/Users/u/Library/Group Containers/2BUA8C4S2C.com.1password"),
            leftover("/Users/u/Library/Preferences/2BUA8C4S2C.com.1password.plist", .preferences),
            leftover("/Users/u/Library/Containers/com.1password.safari"),
        ]
        let onePassword = SharedContainers.OtherApp(name: "1Password", signing: SigningInfo(
            teamID: "2BUA8C4S2C",
            appGroups: ["2BUA8C4S2C.com.1password", "2BUA8C4S2C.com.agilebits"]
        ))

        let split = SharedContainers.partition(found, usedBy: [onePassword])

        XCTAssertEqual(split.kept.map(\.url.lastPathComponent), ["com.1password.safari"])
        // What was held back is reported, with who uses it, so the user is told.
        XCTAssertEqual(split.shared.count, 2)
        XCTAssertEqual(Set(split.shared.flatMap(\.usedBy)), ["1Password"])
    }

    func testKeepsContainersNoOtherAppClaims() {
        let found = [leftover("/Users/u/Library/Group Containers/Q6L2SF6YDW.com.acme.App")]
        let other = SharedContainers.OtherApp(name: "Other", signing: SigningInfo(
            teamID: "Q6L2SF6YDW", appGroups: ["Q6L2SF6YDW.com.acme.Other"]
        ))

        let split = SharedContainers.partition(found, usedBy: [other])
        XCTAssertEqual(split.kept.count, 1)
        XCTAssertTrue(split.shared.isEmpty)
    }

    /// The real 1Password, when installed: its signature must report the group that
    /// holds the SSH agent, or none of this protects it.
    func testReadsAppGroupsFromARealSignature() throws {
        let url = URL(fileURLWithPath: "/Applications/1Password.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("1Password is not installed")
        }
        let info = try XCTUnwrap(SigningInfo.read(bundleURL: url))
        XCTAssertEqual(info.teamID, "2BUA8C4S2C")
        XCTAssertTrue(info.appGroups.contains("2BUA8C4S2C.com.1password"))
    }
}
