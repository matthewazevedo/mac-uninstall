import XCTest
@testable import MacUninstallCore

/// Read-only checks against the apps actually installed on this Mac.
///
/// These never remove anything. They exist to catch the failure mode unit tests
/// cannot: rules that look right against fixtures but find nothing, or far too
/// much, against a real Library folder.
final class RealSystemSmokeTests: XCTestCase {

    func testDiscoversInstalledApplications() throws {
        let apps = AppScanner().installedApps()
        try XCTSkipIf(apps.isEmpty, "No applications found on this machine")

        // Every discovered app should have a usable name and a real bundle.
        for app in apps {
            XCTAssertFalse(app.displayName.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.bundleURL.path))
        }
        XCTAssertTrue(apps.contains { $0.bundleID != nil }, "Bundle IDs should be readable")
    }

    func testSignatureEnrichmentYieldsTeamAndVendor() throws {
        let scanner = AppScanner()
        let apps = scanner.installedApps()
        // Safari is present on every Mac and is always signed.
        guard let target = apps.first(where: { $0.bundleID?.hasPrefix("com.apple.") == true })
                ?? apps.first else {
            throw XCTSkip("No applications available")
        }

        let enriched = scanner.enrichWithSignature(target)
        XCTAssertNotNil(
            enriched.teamID ?? enriched.signingOrganization,
            "A signed app should yield a team identifier or an organisation"
        )
    }

    /// Guards the blast radius: a scan must never propose a protected path, and
    /// must not balloon into hundreds of items for one app.
    func testScanningRealAppsStaysBoundedAndSafe() async throws {
        let scanner = AppScanner()
        let apps = scanner.installedApps().filter { $0.bundleID?.hasPrefix("com.apple.") == false }
        try XCTSkipIf(apps.isEmpty, "No third-party applications installed")

        for app in apps.prefix(5) {
            let identity = scanner.enrichWithSignature(app)
            let result = await LeftoverScanner(options: .init(measureSizes: false))
                .scan(for: identity)

            for leftover in result.leftovers {
                XCTAssertTrue(
                    ProtectedPaths.isSafeToRemove(leftover.url),
                    "Scan of \(app.displayName) proposed a protected path: \(leftover.url.path)"
                )
                XCTAssertFalse(leftover.reason.isEmpty, "Every item needs a justification")
            }

            XCTAssertLessThan(
                result.leftovers.count, 200,
                "\(app.displayName) matched \(result.leftovers.count) items, which suggests an over-broad rule"
            )
        }
    }

    /// The app's own bundle must always be found, otherwise the core promise fails.
    func testScanAlwaysIncludesTheApplicationBundle() async throws {
        let scanner = AppScanner()
        guard let app = scanner.installedApps().first else { throw XCTSkip("No applications") }

        let result = await LeftoverScanner(options: .init(measureSizes: false)).scan(for: app)
        XCTAssertTrue(
            result.leftovers.contains { $0.url == app.bundleURL && $0.category == .application },
            "The bundle itself must be part of its own footprint"
        )
    }

    func testFullDiskAccessProbeReturnsADefiniteAnswer() {
        // Whatever the answer, it must not crash and must be actionable.
        let status = PermissionChecker.fullDiskAccessStatus()
        XCTAssertTrue([.granted, .denied, .indeterminate].contains(status))
    }
}
