import XCTest
@testable import Modore

final class AutomaticCacheRecoveryTests: XCTestCase {
    func testStandingConsentAndPressureAreRequired() {
        let now = Date()
        XCTAssertFalse(AutomaticCachePolicy.shouldRun(enabled: false, free: 0, lastRun: nil, now: now))
        XCTAssertFalse(AutomaticCachePolicy.shouldRun(enabled: true, free: nil, lastRun: nil, now: now))
        XCTAssertFalse(AutomaticCachePolicy.shouldRun(enabled: true, free: AutomaticCachePolicy.target, lastRun: nil, now: now))
        XCTAssertTrue(AutomaticCachePolicy.shouldRun(enabled: true, free: 1, lastRun: nil, now: now))
    }
    func testRestartAndClockRollbackDoNotRepeatCleanup() {
        let now = Date()
        for interval in [0.0, 60, 1799, -600] {
            XCTAssertFalse(AutomaticCachePolicy.shouldRun(enabled: true, free: 1,
                lastRun: now.addingTimeInterval(-interval), now: now))
        }
        XCTAssertTrue(AutomaticCachePolicy.shouldRun(enabled: true, free: 1,
            lastRun: now.addingTimeInterval(-1800), now: now))
    }
    func testScopeExcludesRuntimeAndUserData() {
        XCTAssertEqual(AutomaticCachePolicy.recipes, ["npm_download_cache", "pip_cache", "homebrew_cache"])
    }
    @MainActor func testConcurrentWritesAreReportedAsNegativeGain() {
        let report = AutomaticCacheReport(date: Date(), before: 3_000_000_000,
                                         after: 2_000_000_000, evidence: "test")
        XCTAssertTrue(AutomaticCacheRecovery.summary(report).contains("−"))
    }
}
