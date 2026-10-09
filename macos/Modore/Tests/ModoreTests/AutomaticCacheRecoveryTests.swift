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
    func testMeasuredGrowthOutranksLargeUnchangedDirectories() {
        let lines = AutomaticCachePolicy.evidenceLines([
            ["label": "large simulator", "createdBytes": Int64(50_000_000_000), "recentDeltaBytes": Int64(0)],
            ["label": "tiny change", "recentDeltaBytes": Int64(1024)],
            ["label": "swap", "recentDeltaBytes": Int64(2_147_483_648)],
            ["label": "unknown cache", "createdBytes": Int64(4_000_000_000)],
            ["label": "shrinking files", "recentDeltaBytes": Int64(-2048)],
        ])
        XCTAssertTrue(lines[0].hasPrefix("swap 최근 실측 증가"))
        XCTAssertFalse(lines.joined().contains("large simulator"))
        XCTAssertFalse(lines.joined().contains("shrinking files"))
        XCTAssertTrue(lines.last!.contains("증가량 미확인: unknown cache"))
    }

    func testMissingBaselineDoesNotTurnFileAgeIntoAProvenCause() {
        let lines = AutomaticCachePolicy.evidenceLines([
            ["label": "cache", "createdBytes": Int64(5_000_000_000)]
        ])
        XCTAssertTrue(lines[0].contains("최근 증가가 확인되지 않았습니다"))
        XCTAssertTrue(lines.last!.contains("증가량 미확인: cache"))
        XCTAssertFalse(lines.joined().contains("+"))
    }

    func testScopeProtectsSessionsInstalledAppsSimulatorsAndNPX() {
        XCTAssertTrue(AutomaticCachePolicy.recipes.contains("vscode_update_cache"))
        XCTAssertTrue(AutomaticCachePolicy.recipes.contains("chrome_code_sign_clones"))
        for protected in ["npm_cache", "codex_runtime_cache", "claude_vm_bundles", "ollama_models", "innorix_ex", "simulator_delete"] {
            XCTAssertFalse(AutomaticCachePolicy.recipes.contains(protected))
        }
    }

    func testLargeReadyCandidatesPrecedeSmallCachesAndExcludeBlockedOnes() {
        func candidate(_ id: String, _ bytes: Int64?, _ ready: Bool = true) -> AutomaticRecoveryCandidate {
            AutomaticRecoveryCandidate(recipe: id, label: id, bytes: bytes, ready: ready, reason: "test")
        }
        let result = AutomaticCachePolicy.largestFirst([
            candidate("small", 32 * 1_048_576), candidate("unknown", nil),
            candidate("large", 3 * 1_073_741_824), candidate("active", 10 * 1_073_741_824, false),
            candidate("tiny", 1000),
        ])
        XCTAssertEqual(result.map(\.recipe), ["large", "small"])
    }

    @MainActor func testHalfGiBRecoveryDoesNotClaimSpaceProblemSolved() {
        let report = AutomaticCacheReport(date: Date(), before: 6 * 1_073_741_824,
            after: 6 * 1_073_741_824 + 523 * 1_048_576, evidence: "test", finished: true)
        XCTAssertTrue(AutomaticCacheRecovery.summary(report).contains("공간 부족 지속"))
        XCTAssertGreaterThan(AutomaticCachePolicy.remainingBytes(after: report.after)!, 13 * 1_073_741_824)
        XCTAssertNil(AutomaticCachePolicy.remainingBytes(after: nil))
        XCTAssertEqual(AutomaticCachePolicy.remainingBytes(after: 25 * 1_073_741_824), 0)
    }

    func testOccupancyKeepsPartialCoverageDistinctFromReclaimableSpace() {
        let rows = AutomaticCachePolicy.occupants([
            ["label": "partial", "path": "/cache", "allocatedBytes": Int64(3_000_000_000), "complete": false],
            ["label": "complete", "path": "/runtime", "allocatedBytes": Int64(2_000_000_000), "complete": true],
        ])
        XCTAssertEqual(rows.map(\.label), ["partial", "complete"])
        XCTAssertFalse(rows[0].complete)
        XCTAssertTrue(rows[1].complete)
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
