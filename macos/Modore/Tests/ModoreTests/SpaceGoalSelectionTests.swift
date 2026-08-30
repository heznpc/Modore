import XCTest
@testable import Modore

final class SpaceGoalSelectionTests: XCTestCase {
    private func item(
        label: String,
        sizeGB: Double,
        cleanupID: String = "npm_cache",
        measureStatus: String = "ok",
        path: String? = nil
    ) -> StorageItem {
        StorageItem(json: [
            "risk": "warning",
            "kind": "cache",
            "label": label,
            "sizeGB": sizeGB,
            "path": path ?? "/tmp/\(label)",
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

    func testTimedOutMeasurementIsUnknownAndAppendedOnlyWhenKnownTotalIsShort() {
        let items = [
            item(label: "stale", sizeGB: 50, measureStatus: "timed_out"),
            item(label: "measured", sizeGB: 1),
        ]

        let selected = SpaceGoalSelection.select(from: items, targetGB: 10)

        XCTAssertEqual(selected.map(\.label), ["measured", "stale"])
        XCTAssertEqual(SpaceGoalSelection.planningSizeGB(items[0]), 0)
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

    // The doc comment promises the same candidate set yields the same
    // selection regardless of scan order. Size and label alone do not
    // guarantee that: `label` falls back to `kind`, so two same-size rows of
    // one kind tie completely and the result then depended on emit order.
    func testIdenticalSizeAndLabelStillResolveToOneFixedOrder() {
        let first = item(label: "cache", sizeGB: 0.5, path: "/tmp/a")
        let second = item(label: "cache", sizeGB: 0.5, path: "/tmp/b")

        let forward = SpaceGoalSelection.select(from: [first, second], targetGB: 1)
        let reversed = SpaceGoalSelection.select(from: [second, first], targetGB: 1)

        XCTAssertEqual(forward.map(\.path), reversed.map(\.path))
        XCTAssertEqual(forward.map(\.path), ["/tmp/a", "/tmp/b"])
    }

    func testSelectionOrderIsIndependentOfInputOrderAtTheGoalBoundary() {
        // Only one of the two tied 0.5GB rows is needed to cross the goal, so
        // which one gets picked is exactly where input order used to leak.
        let big = item(label: "big", sizeGB: 2.5)
        let tiedA = item(label: "cache", sizeGB: 0.5, path: "/tmp/a")
        let tiedB = item(label: "cache", sizeGB: 0.5, path: "/tmp/b")

        let forward = SpaceGoalSelection.select(from: [big, tiedA, tiedB], targetGB: 3)
        let reversed = SpaceGoalSelection.select(from: [tiedB, tiedA, big], targetGB: 3)

        XCTAssertEqual(forward.count, 2)
        XCTAssertEqual(forward.map(\.path), reversed.map(\.path))
    }

    // Sizes arrive rounded to a tenth, and a tenth is not exact in binary.
    // 2.4 + 0.3 + 0.3 is exactly 3.0 in decimal but accumulates to
    // 2.9999999999999996 in Double, so a bare `>=` walked past the set that
    // actually meets the goal and appended a fourth item -- then reported the
    // result as short of the goal it had in fact reached.
    func testExactlyMetGoalDoesNotPickUpAnExtraItemFromFloatError() {
        let items = [
            item(label: "a", sizeGB: 2.4),
            item(label: "b", sizeGB: 0.3),
            item(label: "c", sizeGB: 0.3),
            item(label: "d", sizeGB: 0.2),
        ]

        let selected = SpaceGoalSelection.select(from: items, targetGB: 3)

        XCTAssertEqual(selected.map(\.label), ["a", "b", "c"])
    }

    // A non-finite size poisons every sum it enters and makes the goal
    // slider's range precondition trap; it is treated as unmeasured instead.
    func testNonFiniteSizeIsTreatedAsUnmeasured() {
        let poisoned = StorageItem(json: [
            "risk": "warning",
            "kind": "cache",
            "label": "poisoned",
            "sizeGB": "1e999",
            "path": "/tmp/poisoned",
            "measureStatus": "ok",
            "cleanupId": "npm_cache",
        ])!

        XCTAssertEqual(poisoned.sizeGB, 0)
        XCTAssertTrue(poisoned.sizeGB.isFinite)
    }
}
