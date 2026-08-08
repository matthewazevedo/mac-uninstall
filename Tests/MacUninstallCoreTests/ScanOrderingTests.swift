import XCTest
@testable import MacUninstallCore

/// Locations are swept concurrently, so the order results come back in is whatever
/// the filesystem decides. What the user sees must not depend on that.
final class ScanOrderingTests: XCTestCase {

    private func leftover(_ path: String, _ confidence: Confidence) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: path),
            category: .supportFiles,
            confidence: confidence,
            reason: "test"
        )
    }

    func testResultsAreOrderedStrongestFirstWhateverOrderTheyArriveIn() {
        let items = [
            leftover("/Library/Caches/b", .possible),
            leftover("/Library/Caches/a", .certain),
            leftover("/Library/Caches/c", .likely),
        ]

        let forwards = LeftoverScanner.ordered(items)
        let backwards = LeftoverScanner.ordered(items.reversed())

        XCTAssertEqual(forwards.map(\.confidence), [.certain, .likely, .possible])
        XCTAssertEqual(forwards.map(\.id), backwards.map(\.id))
    }

    /// Two sweeps can reach the same path — a location nested inside another, or a
    /// symlinked folder. It must appear once, at the strongest evidence found.
    func testAPathFoundTwiceIsKeptOnceAtItsStrongestConfidence() {
        let ordered = LeftoverScanner.ordered([
            leftover("/Library/Caches/com.acme.App", .possible),
            leftover("/Library/Caches/com.acme.App", .certain),
        ])

        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(ordered.first?.confidence, .certain)
    }

    /// A tree too big to walk within the bound yields a floor, and says so, rather
    /// than a confident number that happens to be wrong.
    func testMeasurementReportsAFloorWhenItHitsItsBound() throws {
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallSize-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        for index in 0..<6 {
            try Data("0123456789".utf8).write(to: directory.appending(path: "file-\(index)"))
        }

        let bounded = try XCTUnwrap(DiskSize.ofItem(at: directory, limit: 2))
        XCTAssertTrue(bounded.isPartial)

        let complete = try XCTUnwrap(DiskSize.ofItem(at: directory))
        XCTAssertFalse(complete.isPartial)
        XCTAssertGreaterThan(complete.bytes, bounded.bytes)
    }

    func testASingleFileIsNeverPartial() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MacUninstallSize-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let measurement = try XCTUnwrap(DiskSize.ofItem(at: file))
        XCTAssertFalse(measurement.isPartial)
        XCTAssertGreaterThan(measurement.bytes, 0)
    }
}
