import SwiftUI
import XCTest
@testable import Modore

/// The goal slider's range is the one place in this view that can take the
/// whole page down: SwiftUI's Slider divides the range by `step` and calls
/// `fatalError("max stride must be positive")` on a zero-width range, which
/// is not catchable. `1...max(achievableGB, 1)` collapsed to `1...1` for any
/// cleanable total in (0, 1]GB -- a single small npm cache -- so the 목표 tab
/// hard-crashed the app. These assert the bound is always strictly above the
/// lower bound, and that the sub-1GB case doesn't render a slider at all.
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
