import XCTest
@testable import LagQA

final class ProtocolTests: XCTestCase {
    func testUserRecordingNeverFinishesOnOldTimerBoundaries() {
        for elapsed in [0.0, 8, 12, 40, 80, 600, 3600] {
            XCTAssertFalse(RecordingPolicy.shouldFinish(elapsed: elapsed, smoke: false))
        }
        XCTAssertFalse(RecordingPolicy.shouldFinish(elapsed: 11.9, smoke: true))
        XCTAssertTrue(RecordingPolicy.shouldFinish(elapsed: 12, smoke: true))
    }
    func testCPUUsesElapsedCountersAndRejectsPIDReuse() {
        let old = CPUCounter(birth: 1, totalNanoseconds: 2_000_000_000, timestamp: 10)
        let now = CPUCounter(birth: 1, totalNanoseconds: 5_000_000_000, timestamp: 12)
        XCTAssertEqual(CPUCounter.percent(previous: old, current: now), 150)
        XCTAssertNil(CPUCounter.percent(previous: old, current: .init(birth: 2, totalNanoseconds: 5_000_000_000, timestamp: 12)))
        XCTAssertNil(CPUCounter.percent(previous: old, current: .init(birth: 1, totalNanoseconds: 1, timestamp: 12)))
        XCTAssertNil(CPUCounter.percent(previous: old, current: old))
    }
}
