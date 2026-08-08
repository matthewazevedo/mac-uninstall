import MacUninstallCore
import XCTest
@testable import MacUninstallAppCore

/// The model decides what is ticked before anything is removed, which makes it part
/// of the safety story rather than a detail of the views.
@MainActor
final class AppModelTests: XCTestCase {

    private func identity(_ name: String, at path: String, bundleID: String? = nil) -> AppIdentity {
        AppIdentity(
            bundleURL: URL(fileURLWithPath: path),
            bundleID: bundleID,
            displayName: name
        )
    }

    private func leftover(
        _ path: String,
        _ confidence: Confidence = .certain,
        admin: Bool = false,
        size: Int64? = nil,
        partial: Bool = false
    ) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: path),
            category: .supportFiles,
            confidence: confidence,
            reason: "test",
            sizeBytes: size,
            sizeIsPartial: partial,
            requiresAdmin: admin
        )
    }

    private func makeModel(with leftovers: [Leftover]) -> AppModel {
        let model = AppModel()
        model.scanResult = ScanResult(
            identity: identity("Acme", at: "/Applications/Acme.app", bundleID: "com.acme.App"),
            leftovers: leftovers
        )
        return model
    }

    // MARK: - The app list

    func testSearchMatchesNameOrIdentifier() {
        let model = AppModel()
        model.installedApps = [
            identity("Acme", at: "/Applications/Acme.app", bundleID: "com.acme.App"),
            identity("Birdo", at: "/Applications/Birdo.app", bundleID: "com.birdo.App"),
        ]

        model.searchText = "birdo"
        XCTAssertEqual(model.filteredApps.map(\.displayName), ["Birdo"])

        model.searchText = "com.acme"
        XCTAssertEqual(model.filteredApps.map(\.displayName), ["Acme"])

        model.searchText = ""
        XCTAssertEqual(model.filteredApps.count, 2)
    }

    /// Apple's own apps are listed so the sidebar matches Finder, but they are split
    /// out because their bundles cannot be removed.
    func testSystemAppsAreSeparatedFromRemovableOnes() {
        let model = AppModel()
        model.installedApps = [
            identity("Acme", at: "/Applications/Acme.app"),
            identity("Mail", at: "/System/Applications/Mail.app"),
        ]

        XCTAssertEqual(model.removableApps.map(\.displayName), ["Acme"])
        XCTAssertEqual(model.systemApps.map(\.displayName), ["Mail"])
    }

    // MARK: - Selection

    /// Only unambiguous matches are ticked. Everything else is a decision the user
    /// has to make, which is the entire argument the review screen makes.
    func testSelectingCertainOnlyLeavesEverythingElseUnticked() {
        let model = makeModel(with: [
            leftover("/Users/x/Library/Caches/com.acme.App", .certain),
            leftover("/Users/x/Library/Application Support/Acme", .likely),
            leftover("/Users/x/Library/Application Support/AcmeSoft", .possible),
        ])

        model.selectAll()
        XCTAssertEqual(model.selectedLeftovers.count, 3)
        XCTAssertTrue(model.selectionIncludesUnreviewed)

        model.selectCertainOnly()
        XCTAssertEqual(model.selectedLeftovers.map(\.confidence), [.certain])
        XCTAssertFalse(model.selectionIncludesUnreviewed)
    }

    func testTogglingAndGroupSelectionTrackTheSameSet() {
        let items = [
            leftover("/Users/x/Library/Caches/one"),
            leftover("/Users/x/Library/Caches/two"),
        ]
        let model = makeModel(with: items)
        model.selectedPaths = []

        model.toggle(items[0])
        XCTAssertEqual(model.selectedLeftovers.count, 1)
        model.toggle(items[0])
        XCTAssertTrue(model.selectedLeftovers.isEmpty)

        model.setSelection(true, for: items)
        XCTAssertEqual(model.selectedLeftovers.count, 2)
        model.setSelection(false, for: items)
        XCTAssertTrue(model.selectedLeftovers.isEmpty)
    }

    func testTheFooterKnowsWhenTheSelectionNeedsAPasswordOrIsOnlyAFloor() {
        let model = makeModel(with: [
            leftover("/Library/LaunchDaemons/com.acme.plist", admin: true, size: 100),
            leftover("/Users/x/Library/Caches/com.acme.App", size: 900, partial: true),
        ])
        model.selectAll()

        XCTAssertTrue(model.selectionNeedsAdmin)
        XCTAssertEqual(model.selectedSizeBytes, 1000)
        XCTAssertTrue(model.selectedSizeIsPartial, "One unmeasurable item makes the total a floor")
    }

    // MARK: - Sizes arriving late

    /// Sizes are measured after the list is on screen, and a big Library takes
    /// seconds. If the user has moved on, those numbers belong to another app.
    func testMeasurementsForAPreviousScanAreDiscarded() {
        let item = leftover("/Users/x/Library/Caches/com.acme.App")
        let model = makeModel(with: [item])

        var measured = item
        measured.sizeBytes = 4096

        model.applyMeasuredSizes([measured], from: URL(fileURLWithPath: "/Applications/Birdo.app"))
        XCTAssertNil(model.scanResult?.leftovers.first?.sizeBytes, "Wrong app, wrong numbers")

        model.applyMeasuredSizes([measured], from: URL(fileURLWithPath: "/Applications/Acme.app"))
        XCTAssertEqual(model.scanResult?.leftovers.first?.sizeBytes, 4096)
    }

    // MARK: - Drops

    func testDroppingSomethingThatIsNotAnAppSaysSoRatherThanScanning() {
        let model = AppModel()
        model.handleDrop(url: URL(fileURLWithPath: "/Users/x/Documents/notes.txt"))

        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.scanResult)
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: - Formatting

    func testAPartialMeasurementIsShownAsAFloor() {
        XCTAssertEqual(Int64(1_000).formattedBytes(partial: false), Int64(1_000).formattedBytes)
        XCTAssertTrue(Int64(1_000).formattedBytes(partial: true).hasPrefix("≥ "))
        XCTAssertEqual(leftover("/x", size: nil).sizeDescription, "—")
    }
}

@MainActor
final class RunningAppGuardTests: XCTestCase {

    /// A bare prefix test also matches `Acme.app.backup`, which is a different app
    /// that happens to sort next to this one.
    func testBundleContainmentRequiresAPathSeparator() {
        let bundle = URL(fileURLWithPath: "/Applications/Acme.app")

        XCTAssertTrue(RunningAppGuard.isInside(bundle, bundle: bundle))
        XCTAssertTrue(RunningAppGuard.isInside(
            URL(fileURLWithPath: "/Applications/Acme.app/Contents/MacOS/Acme"), bundle: bundle
        ))
        XCTAssertFalse(RunningAppGuard.isInside(
            URL(fileURLWithPath: "/Applications/Acme.app.backup/Contents/MacOS/Acme"), bundle: bundle
        ))
        XCTAssertFalse(RunningAppGuard.isInside(
            URL(fileURLWithPath: "/Applications/Birdo.app"), bundle: bundle
        ))
    }
}
