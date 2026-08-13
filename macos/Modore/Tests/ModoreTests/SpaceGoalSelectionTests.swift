import XCTest
@testable import Modore

final class SpaceGoalSelectionTests: XCTestCase {
    private func item(
        label: String,
        sizeGB: Double,
        cleanupID: String = "npm_cache",
        measureStatus: String = "ok"
    ) -> StorageItem {
        StorageItem(json: [
            "risk": "warning",
            "kind": "cache",
            "label": label,
            "sizeGB": sizeGB,
            "path": "/tmp/\(label)",
            "action": "정리",
            "note": "",
            "measureStatus": measureStatus,
            "cleanupId": cleanupID,
        ])!
    }

    // Labels are deliberately in the opposite order from their sizes: if
    // selection ever fell back to array/alphabetical order instead of
    // sorting by size, this would select 3 small-first items instead of the
    // 2 large ones, so the assertion would catch it either way.
    func testPicksFewestLargestItemsToReachTarget() {
        let items = [
            item(label: "alpha", sizeGB: 1),
            item(label: "beta", sizeGB: 8),
            item(label: "gamma", sizeGB: 4),
        ]

        let selected = SpaceGoalSelection.select(from: items, targetGB: 10)

        XCTAssertEqual(selected.map(\.label), ["beta", "gamma"])
    }

    func testStopsAsSoonAsTargetIsMet() {
        let items = [
            item(label: "a", sizeGB: 6),
            item(label: "b", sizeGB: 6),
            item(label: "c", sizeGB: 6),
        ]

        let selected = SpaceGoalSelection.select(from: items, targetGB: 10)

        XCTAssertEqual(selected.count, 2)
    }

    func testReturnsEverythingEligibleWhenTargetExceedsWhatsAvailable() {
        let items = [item(label: "a", sizeGB: 1), item(label: "b", sizeGB: 2)]

        let selected = SpaceGoalSelection.select(from: items, targetGB: 100)

        XCTAssertEqual(selected.count, 2)
    }

    // A huge manual-review-only path (no cleanup recipe) must never be
    // "selected" -- goal mode can only promise what it can actually preview.
    func testExcludesItemsWithoutASupportedCleanupRecipe() {
        let items = [
            item(label: "unsupported", sizeGB: 50, cleanupID: ""),
            item(label: "supported", sizeGB: 1),
        ]

        let selected = SpaceGoalSelection.select(from: items, targetGB: 10)

        XCTAssertEqual(selected.map(\.label), ["supported"])
    }

    func testExcludesTimedOutMeasurements() {
        let items = [
            item(label: "stale", sizeGB: 50, measureStatus: "timed_out"),
            item(label: "measured", sizeGB: 1),
        ]

        let selected = SpaceGoalSelection.select(from: items, targetGB: 10)

        XCTAssertEqual(selected.map(\.label), ["measured"])
    }

    // Same-size items must resolve to the same order regardless of scan
    // ordering, or the same candidate set could produce a different
    // "combination" from one scan to the next.
    func testTiesBreakByLabelForDeterminism() {
        let items = [
            item(label: "zeta", sizeGB: 5),
            item(label: "alpha", sizeGB: 5),
        ]

        let selected = SpaceGoalSelection.select(from: items, targetGB: 5)

        XCTAssertEqual(selected.map(\.label), ["alpha"])
    }

    func testZeroOrNegativeTargetSelectsNothing() {
        let items = [item(label: "a", sizeGB: 5)]

        XCTAssertEqual(SpaceGoalSelection.select(from: items, targetGB: 0).count, 0)
        XCTAssertEqual(SpaceGoalSelection.select(from: items, targetGB: -1).count, 0)
    }
}
