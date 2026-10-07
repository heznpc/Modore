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

    func testNoRepeatedWarningForSameUnchangedBlockers() {
        var before = AutomaticCacheReport(date: Date(), before: 8_000_000_000,
            after: 8_000_000_000, evidence: "old", outcomes: ["npm in use"], finished: true)
        var next = before
        next.after = 6_000_000_000
        next.evidence = "new observation"
        XCTAssertFalse(AutomaticCachePolicy.shouldNotify(next, previous: before))
        next.after = 2_000_000_000
        XCTAssertTrue(AutomaticCachePolicy.shouldNotify(next, previous: before))
        before = next
        XCTAssertFalse(AutomaticCachePolicy.shouldNotify(next, previous: before))
        next.receipts = ["verified receipt"]
        XCTAssertTrue(AutomaticCachePolicy.shouldNotify(next, previous: before))
    }
    func testManagedReminderDoesNotHideCriticalOrUnmanagedState() {
        XCTAssertTrue(AutomaticCachePolicy.ownsStorageNotice(enabled: true, appRunning: true, free: 6_000_000_000))
        XCTAssertFalse(AutomaticCachePolicy.ownsStorageNotice(enabled: true, appRunning: false, free: 6_000_000_000))
        XCTAssertFalse(AutomaticCachePolicy.ownsStorageNotice(enabled: false, appRunning: true, free: 6_000_000_000))
        XCTAssertFalse(AutomaticCachePolicy.ownsStorageNotice(enabled: true, appRunning: true, free: 2_000_000_000))
        XCTAssertFalse(AutomaticCachePolicy.ownsStorageNotice(enabled: true, appRunning: true, free: nil))
    }
}
