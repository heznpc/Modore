import SwiftUI
import XCTest
@testable import Modore

/// Keep the small/empty candidate cases that crashed the former goal slider.
/// The target now uses a stepper independent of estimated candidate sizes;
/// these render checks preserve coverage for all those storage states.
final class SpaceGoalViewRangeTests: XCTestCase {
    private func snapshot(cleanableGB: [Double]) -> StorageSnapshot {
        let candidates = cleanableGB.enumerated().map { index, size in
            [
                "risk": "warning",
                "kind": "cache",
                "label": "cache-\(index)",
                "sizeGB": size,
                "path": "/tmp/cache-\(index)",
                "action": "정리",
                "note": "",
                "measureStatus": "ok",
                "cleanupId": "npm_cache",
            ] as [String: Any]
        }
        return StorageSnapshot(json: [
            "volume": [
                "mount": "/", "freeGB": 30, "usedGB": 70,
                "totalGB": 100, "usePercent": 70, "risk": "safe",
            ],
            "cleanupCandidates": candidates,
        ])!
    }

    @MainActor
    private func renderGoalTab(cleanableGB: [Double]) {
        let view = SpaceGoalWorkspaceList(storage: snapshot(cleanableGB: cleanableGB))
            .environmentObject(ScanModel(automaticallyScansStaleResults: false))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
    }

    /// The exact crash: cleanable total greater than zero but at or below 1GB.
    @MainActor
    func testRendersWithASubOneGigabyteCleanableTotal() {
        renderGoalTab(cleanableGB: [0.5])
    }

    @MainActor
    func testRendersWhenEveryCandidateMeasuresZero() {
        renderGoalTab(cleanableGB: [0, 0])
    }

    @MainActor
    func testRendersAtExactlyOneGigabyte() {
        renderGoalTab(cleanableGB: [1.0])
    }

    @MainActor
    func testRendersWithAnOrdinaryMultiGigabyteTotal() {
        renderGoalTab(cleanableGB: [1.5, 1.5, 1.4])
    }

    @MainActor
    func testRendersWithNoCandidatesAtAll() {
        renderGoalTab(cleanableGB: [])
    }
}
