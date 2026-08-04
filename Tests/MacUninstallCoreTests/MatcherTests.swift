import XCTest
@testable import MacUninstallCore

final class MatcherTests: XCTestCase {

    /// A stand-in modelled on a real app: reverse-DNS ID, a vendor with a legal
    /// suffix, a helper bundle, and a distinct executable name.
    private func acme(
        bundleID: String? = "com.acmesoft.Sketchpad",
        displayName: String = "Sketchpad",
        executable: String? = "Sketchpad",
        organization: String? = "AcmeSoft Inc.",
        team: String? = "AB12CD34EF",
        helpers: Set<String> = ["com.acmesoft.Sketchpad.Updater"]
    ) -> AppIdentity {
        AppIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Sketchpad.app"),
            bundleID: bundleID,
            displayName: displayName,
            executableName: executable,
            teamID: team,
            signingOrganization: organization,
            helperBundleIDs: helpers
        )
    }

    // MARK: - Certain matches

    func testExactBundleIDIsCertain() {
        let matcher = Matcher(identity: acme())
        let match = matcher.match(name: "com.acmesoft.Sketchpad.plist", isDirectory: false)
        XCTAssertEqual(match?.confidence, .certain)
    }

    func testDottedChildOfBundleIDIsCertain() {
        let matcher = Matcher(identity: acme())
        XCTAssertEqual(
            matcher.match(name: "com.acmesoft.Sketchpad.helper.plist", isDirectory: false)?.confidence,
            .certain
        )
    }

    func testHelperBundleIDIsCertain() {
        let matcher = Matcher(identity: acme())
        XCTAssertEqual(
            matcher.match(name: "com.acmesoft.Sketchpad.Updater", isDirectory: true)?.confidence,
            .certain
        )
    }

    func testSavedStateSuffixIsStripped() {
        let matcher = Matcher(identity: acme())
        XCTAssertEqual(
            matcher.match(name: "com.acmesoft.Sketchpad.savedState", isDirectory: true)?.confidence,
            .certain
        )
    }

    /// The separator rule stops a bundle ID from claiming a different product
    /// whose identifier merely starts with the same characters.
    func testDoesNotClaimDifferentProductWithSharedPrefixText() {
        let matcher = Matcher(identity: acme())
        let match = matcher.match(name: "com.acmesoft.SketchpadPro.plist", isDirectory: false)
        XCTAssertNotEqual(match?.confidence, .certain)
    }

    // MARK: - Likely matches

    func testSiblingReverseDNSIsLikelyNotCertain() {
        let matcher = Matcher(identity: acme())
        // A shared vendor updater: belongs to the vendor, maybe not to this app.
        let match = matcher.match(name: "com.acmesoft.SharedUpdater.plist", isDirectory: false)
        XCTAssertEqual(match?.confidence, .likely)
        XCTAssertFalse(match!.confidence.selectedByDefault)
    }

    func testTeamIdentifierPrefixedGroupContainerIsLikely() {
        let identity = acme(bundleID: "com.other.Thing", helpers: [])
        let matcher = Matcher(identity: identity)
        XCTAssertEqual(
            matcher.match(name: "AB12CD34EF.com.shared.group", isDirectory: true)?.confidence,
            .likely
        )
    }

    func testDisplayNameFolderIsLikely() {
        let matcher = Matcher(identity: acme())
        XCTAssertEqual(matcher.match(name: "Sketchpad", isDirectory: true)?.confidence, .likely)
    }

    // MARK: - Possible matches

    func testVendorFolderIsOnlyPossibleAndNotAutoSelected() {
        let matcher = Matcher(identity: acme())
        let match = matcher.match(name: "AcmeSoft", isDirectory: true)
        XCTAssertEqual(match?.confidence, .possible)
        XCTAssertFalse(match!.confidence.selectedByDefault, "Vendor folders must never be pre-ticked")
    }

    func testLegalSuffixIsStrippedFromVendorName() {
        let identity = acme(organization: "BraveSoftware Inc.")
        XCTAssertTrue(identity.vendorNames.contains("BraveSoftware"))
    }

    // MARK: - Refusals

    func testAppleFilesAreNeverAttributedToThirdPartyApps() {
        let matcher = Matcher(identity: acme())
        XCTAssertNil(matcher.match(name: "com.apple.finder.plist", isDirectory: false))
        XCTAssertNil(matcher.match(name: "group.com.apple.mail.plist", isDirectory: false))
    }

    func testGenericDisplayNamesDoNotMatch() {
        // An app literally called "Notes" must not claim every Notes folder.
        let matcher = Matcher(identity: acme(
            bundleID: "com.example.notes", displayName: "Notes", executable: "Notes", organization: nil, helpers: []
        ))
        XCTAssertNil(matcher.match(name: "Notes", isDirectory: true))
    }

    func testShortNamesAreRejectedAsIndistinctive() {
        XCTAssertFalse(Matcher.isDistinctive("Arc"))
        XCTAssertFalse(Matcher.isDistinctive("updater"))
        XCTAssertTrue(Matcher.isDistinctive("Sketchpad"))
    }

    func testUnrelatedNamesDoNotMatch() {
        let matcher = Matcher(identity: acme())
        for name in ["com.google.Chrome.plist", "Microsoft", "Spotify", "com.zzz.Other"] {
            XCTAssertNil(matcher.match(name: name, isDirectory: true), "\(name) should not match")
        }
    }

    // MARK: - Identity derivation

    func testVendorNameDerivedFromBundleIDSkipsGenericLeadingSegment() {
        let identity = AppIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/X.app"),
            bundleID: "com.bravesoftware.Browser",
            displayName: "X"
        )
        XCTAssertTrue(identity.vendorNames.contains("bravesoftware"))
        XCTAssertFalse(identity.vendorNames.contains("com"))
    }

    func testReverseDNSPrefixRequiresThreeSegments() {
        let twoSegments = AppIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/X.app"),
            bundleID: "com.acme",
            displayName: "X"
        )
        XCTAssertNil(twoSegments.reverseDNSPrefix)
        XCTAssertEqual(acme().reverseDNSPrefix, "com.acmesoft")
    }

    func testSigningAuthorityOrganizationIsParsed() {
        let line = "Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)"
        XCTAssertEqual(AppScanner.organization(fromAuthority: line), "Anthropic PBC")
    }

    func testVendorNameStripsSuffixPunctuation() {
        // "Turing Software, LLC" must not yield a vendor name with a trailing comma,
        // which would never match a real folder.
        let identity = acme(organization: "Turing Software, LLC")
        XCTAssertTrue(identity.vendorNames.contains("Turing Software"))
        XCTAssertFalse(identity.vendorNames.contains { $0.hasSuffix(",") })
    }

    func testVendorNameHandlesSuffixWithoutPunctuation() {
        XCTAssertTrue(acme(organization: "Tailscale Inc.").vendorNames.contains("Tailscale"))
        XCTAssertTrue(acme(organization: "Anthropic PBC").vendorNames.contains("Anthropic"))
    }
}

extension MatcherTests {

    /// Scanning one of Apple's own apps must not sweep in the rest of macOS.
    ///
    /// `com.apple.Safari` yields the reverse-DNS prefix `com.apple`, which would
    /// otherwise match every system file on the machine — a real scan produced 1,899
    /// items including Spotlight's and the Dock's data.
    func testAppleAppDoesNotClaimUnrelatedSystemFiles() {
        let safari = AppIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            executableName: "Safari",
            signingOrganization: "Apple Inc."
        )
        let matcher = Matcher(identity: safari)

        for name in [
            "com.apple.spotlight", "com.apple.wallpaper", "com.apple.dock.plist",
            "com.apple.sharedfilelist", "com.apple.shazamd", "group.com.apple.notes",
        ] {
            XCTAssertNil(
                matcher.match(name: name, isDirectory: true),
                "\(name) belongs to macOS, not to Safari"
            )
        }
    }

    /// Its own files are still found by exact and dotted-child identifier match.
    func testAppleAppStillMatchesItsOwnFiles() {
        let safari = AppIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            executableName: "Safari"
        )
        let matcher = Matcher(identity: safari)

        XCTAssertEqual(matcher.match(name: "com.apple.Safari.plist", isDirectory: false)?.confidence, .certain)
        XCTAssertEqual(matcher.match(name: "com.apple.Safari.SandboxBroker", isDirectory: true)?.confidence, .certain)

        // A bare "Safari" folder is deliberately NOT matched. Common product names are
        // treated as indistinctive so that a third-party app called Notes or Mail
        // cannot claim an unrelated folder of the same name. The cost is that
        // ~/Library/Safari is missed for Apple's Safari, which cannot be uninstalled
        // anyway — a trade made in favour of never over-matching.
        XCTAssertNil(matcher.match(name: "Safari", isDirectory: true))
    }

    /// A genuine vendor namespace must keep working.
    func testNarrowVendorPrefixesStillMatchSiblings() {
        let chrome = AppIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Chrome.app"),
            bundleID: "com.google.Chrome",
            displayName: "Chrome"
        )
        XCTAssertEqual(
            Matcher(identity: chrome).match(name: "com.google.Keystone.Agent", isDirectory: true)?.confidence,
            .likely
        )
    }
}
