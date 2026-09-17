import XCTest
@testable import Modore

final class HealthNoticePolicyTests: XCTestCase {
    private func sample(_ time: Double, freeGiB: Int64 = 30, pressure: Int = 1,
                        cpuElevated: Bool = false, thermal: Int = 0) -> HealthSnapshot {
        HealthSnapshot(date: Date(timeIntervalSince1970: time), freeBytes: freeGiB * 1_073_741_824,
                       swapBytes: 0, memoryPressure: pressure, thermalPressure: thermal,
                       processes: [.init(pid: 1, name: "test", cpu: 1, residentBytes: 100, workspace: nil)],
                       cpuElevated: cpuElevated)
    }

    func testStorageEscalatesEvenWhenJournalLabelsStayTheSame() {
        var policy = HealthNoticePolicy()
        var journal = HealthJournal()
        for (time, free) in [(0.0, Int64(19)), (60.0, 9), (120.0, 4), (180.0, 2)] {
            let current = sample(time, freeGiB: free)
            let changed = journal.observe(current)
            if free == 9 || free == 2 { XCTAssertFalse(changed) }
            XCTAssertTrue(policy.shouldSend(current, journalChanged: changed, userPresent: true, now: current.date))
            policy.didAttempt(current, accepted: true, now: current.date)
        }
        let repeated = sample(240, freeGiB: 2)
        XCTAssertFalse(policy.shouldSend(repeated, journalChanged: false, userPresent: true, now: repeated.date))
    }

    func testAbsentUserDoesNotConsumeNewIncident() {
        var policy = HealthNoticePolicy()
        let current = sample(0, pressure: 2)
        XCTAssertFalse(policy.shouldSend(current, journalChanged: true, userPresent: false, now: current.date))
        XCTAssertTrue(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                       now: Date(timeIntervalSince1970: 2)))
    }

    func testRejectedDeliveryRetriesAndPersistentLowSpaceRemindsAtThirtyMinutes() {
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
                                        now: delivered.addingTimeInterval(1_799)))
        XCTAssertTrue(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                       now: delivered.addingTimeInterval(1_800)))
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

    func testCriticalPressureDoesNotWaitSixHoursForAnotherWarning() {
        var policy = HealthNoticePolicy()
        let current = sample(0, freeGiB: 2)
        policy.didAttempt(current, accepted: true, now: current.date)
        XCTAssertFalse(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                        now: Date(timeIntervalSince1970: 299)))
        XCTAssertTrue(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                       now: Date(timeIntervalSince1970: 300)))
    }

    func testReturningRAMPressureIsNotHiddenByOpenStorageIncident() {
        var policy = HealthNoticePolicy()
        var journal = HealthJournal()
        let first = sample(0, freeGiB: 16, pressure: 2)
        XCTAssertTrue(policy.shouldSend(first, journalChanged: journal.observe(first), userPresent: true, now: first.date))
        policy.didAttempt(first, accepted: true, now: first.date)
        let normalRAM = sample(60, freeGiB: 16)
        XCTAssertFalse(policy.shouldSend(normalRAM, journalChanged: journal.observe(normalRAM), userPresent: true, now: normalRAM.date))
        let returned = sample(120, freeGiB: 16, pressure: 2)
        XCTAssertFalse(journal.observe(returned))
        XCTAssertTrue(policy.shouldSend(returned, journalChanged: false, userPresent: true, now: returned.date))
        policy.didAttempt(returned, accepted: true, now: returned.date)
        let critical = sample(180, freeGiB: 16, pressure: 4)
        XCTAssertTrue(policy.shouldSend(critical, journalChanged: false, userPresent: true, now: critical.date))
    }

    func testSustainedCPUAndRAMRemindWithoutStoragePressure() {
        for current in [sample(0, pressure: 2), sample(0, cpuElevated: true)] {
            var policy = HealthNoticePolicy()
            policy.didAttempt(current, accepted: true, now: current.date)
            XCTAssertFalse(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                            now: current.date.addingTimeInterval(599)))
            XCTAssertTrue(policy.shouldSend(current, journalChanged: false, userPresent: true,
                                           now: current.date.addingTimeInterval(600)))
        }
    }

    func testRecurrentCPUAndThermalEscalationBypassHistoricalLabels() {
        var policy = HealthNoticePolicy()
        let first = sample(0, freeGiB: 16, cpuElevated: true)
        policy.didAttempt(first, accepted: true, now: first.date)
        let cooled = sample(60, freeGiB: 16)
        XCTAssertFalse(policy.shouldSend(cooled, journalChanged: false, userPresent: true, now: cooled.date))
        let returned = sample(180, freeGiB: 16, cpuElevated: true)
        XCTAssertTrue(policy.shouldSend(returned, journalChanged: false, userPresent: true, now: returned.date))
        policy.didAttempt(returned, accepted: true, now: returned.date)
        let hot = sample(240, freeGiB: 16, cpuElevated: true, thermal: 1)
        XCTAssertTrue(policy.shouldSend(hot, journalChanged: false, userPresent: true, now: hot.date))
    }
}
