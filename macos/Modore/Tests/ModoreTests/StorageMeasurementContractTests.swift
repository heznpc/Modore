import XCTest
@testable import Modore

final class StorageMeasurementContractTests: XCTestCase {
    private func item(status: String, size: Any, lowerBound: Double? = nil) -> StorageItem {
        var json: [String: Any] = [
            "kind": "cache", "label": status, "path": "/cache/\(status)",
            "cleanupId": "npm_cache", "measureStatus": status, "sizeGB": size,
        ]
        if let lowerBound { json["lowerBoundGB"] = lowerBound }
        return StorageItem(json: json)!
    }

    private func countedReviewTotal(_ item: StorageItem) -> Double {
        StorageSnapshot(json: [
            "volume": ["totalGB": 100],
            "reviewCandidates": [[
                "kind": item.kind, "label": item.label, "path": item.path,
                "sizeGB": item.sizeGB, "measureStatus": item.measureStatus,
            ]],
        ])!.reviewGB
    }

    func testIncompleteStatesCannotContributeStaleBytesOrUnlockCleanup() {
        for status in ["deferred", "timed_out", "blocked", "partial", "failed", "unknown", "future-state"] {
            let candidate = item(status: status, size: 99.0)
            XCTAssertNil(candidate.measuredSizeGB, status)
            XCTAssertFalse(candidate.canCleanup, status)
            XCTAssertTrue(candidate.hasSupportedCleanupRecipe, status)
            XCTAssertTrue(SpaceGoalSelection.isPlanningCandidate(candidate), status)
            XCTAssertEqual(SpaceGoalSelection.planningBytes(candidate), 0, status)
            XCTAssertEqual(countedReviewTotal(candidate), 0, status)
        }
    }

    func testMissingSizeAndMeasuredEmptyDirectoryRemainDistinct() {
        let unknown = item(status: "ok", size: NSNull())
        let empty = item(status: "ok", size: 0.0)
        XCTAssertEqual(unknown.measurementStatus, .unknown)
        XCTAssertNil(unknown.measuredSizeGB)
        XCTAssertFalse(unknown.canCleanup)
        XCTAssertEqual(empty.measuredSizeGB, 0)
        XCTAssertTrue(empty.isMeasurementComplete)
        XCTAssertFalse(SpaceGoalSelection.isPlanningCandidate(empty))
    }

    func testPartialLowerBoundIsDisplayEvidenceOnly() {
        let partial = item(status: "partial", size: NSNull(), lowerBound: 3)
        XCTAssertEqual(partial.sizeGB, 3)
        XCTAssertNil(partial.measuredSizeGB)
        XCTAssertEqual(countedReviewTotal(partial), 0)
        XCTAssertEqual(SpaceGoalSelection.planningBytes(partial), 0)
    }

    func testInvalidCompleteSizesFailClosed() {
        for size in [-1.0, Double.infinity, Double.nan, "not-a-size"] as [Any] {
            let candidate = item(status: "ok", size: size)
            XCTAssertEqual(candidate.measurementStatus, .unknown)
            XCTAssertNil(candidate.measuredSizeGB)
            XCTAssertFalse(candidate.canCleanup)
        }
    }
}
