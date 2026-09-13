import XCTest
@testable import Modore

final class HealthNoticePolicyTests: XCTestCase {
    private func sample(_ time: Double, freeGiB: Int64 = 30, pressure: Int = 1) -> HealthSnapshot {
        HealthSnapshot(date: Date(timeIntervalSince1970: time), freeBytes: freeGiB * 1_073_741_824,
                       swapBytes: 0, memoryPressure: pressure, thermalPressure: 0,
                       processes: [.init(pid: 1, name: "test", cpu: 1, residentBytes: 100, workspace: nil)],
                       cpuElevated: false)
    }

    func testStorageEscalatesEvenWhenJournalLabelsStayTheSame() {
        var policy = HealthNoticePolicy()
        var journal = HealthJournal()
        for (time, free) in [(0.0, Int64(19)), (60.0, 9), (120.0, 4)] {
            let current = sample(time, freeGiB: free)
            let changed = journal.observe(current)
            if free == 9 { XCTAssertFalse(changed) }
            XCTAssertTrue(policy.shouldSend(current, journalChanged: changed, userPresent: true, now: current.date))
            policy.didAttempt(current, accepted: true, now: current.date)
        }
        let repeated = sample(180, freeGiB: 4)
        XCTAssertFalse(policy.shouldSend(repeated, journalChanged: false, userPresent: true, now: repeated.date))
    }

    func testAbsentUserDoesNotConsumeNewIncident() {
        var policy = HealthNoticePolicy()
        let current = sample(0, pressure: 2)
        XCTAssertFalse(policy.shouldSend(current, journalChanged: true, userPresent: false, now: current.date))
        XCTAssertTrue(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                       now: Date(timeIntervalSince1970: 2)))
    }

    func testRejectedDeliveryRetriesAndPersistentLowSpaceRemindsAfterSixHours() {
        var policy = HealthNoticePolicy()
        let current = sample(0, freeGiB: 6)
        XCTAssertTrue(policy.shouldSend(current, journalChanged: true, userPresent: true, now: current.date))
        policy.didAttempt(current, accepted: false, now: current.date)
        XCTAssertFalse(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                        now: Date(timeIntervalSince1970: 59)))
        let delivered = Date(timeIntervalSince1970: 60)
        XCTAssertTrue(policy.shouldSend(current, journalChanged: false, userPresent: true, now: delivered))
        policy.didAttempt(current, accepted: true, now: delivered)
        XCTAssertFalse(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                        now: delivered.addingTimeInterval(21_599)))
        XCTAssertTrue(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                       now: delivered.addingTimeInterval(21_600)))
    }

    func testOtherChangesWaitForCooldownWithoutBeingLost() {
        var policy = HealthNoticePolicy()
        let current = sample(0, pressure: 2)
        policy.didAttempt(current, accepted: true, now: current.date)
        XCTAssertFalse(policy.shouldSend(current, journalChanged: true, userPresent: true,
                                        now: Date(timeIntervalSince1970: 59)))
        XCTAssertTrue(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                       now: Date(timeIntervalSince1970: 60)))
    }

    func testHealthyStartAndRecoveredUnseenIncidentStayQuiet() {
        var policy = HealthNoticePolicy()
        let low = sample(0, freeGiB: 6)
        XCTAssertFalse(policy.shouldSend(low, journalChanged: true, userPresent: false, now: low.date))
        let healthy = sample(120)
        XCTAssertFalse(policy.shouldSend(healthy, journalChanged: true, userPresent: true, now: healthy.date))
    }
}
