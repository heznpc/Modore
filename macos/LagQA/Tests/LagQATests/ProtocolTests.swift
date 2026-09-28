import XCTest
import Darwin
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
        let old = CPUCounter(birth: 1, totalTicks: 2_000_000_000, timestamp: 10)
        let now = CPUCounter(birth: 1, totalTicks: 5_000_000_000, timestamp: 12)
        XCTAssertEqual(CPUCounter.percent(previous: old, current: now, nanosecondsPerTick: 1), 150)
        XCTAssertNil(CPUCounter.percent(previous: old, current: .init(birth: 2, totalTicks: 5_000_000_000, timestamp: 12)))
        XCTAssertNil(CPUCounter.percent(previous: old, current: .init(birth: 1, totalTicks: 1, timestamp: 12)))
        XCTAssertNil(CPUCounter.percent(previous: old, current: old))
    }
    func testARMTimebaseConversion() {
        let old = CPUCounter(birth: 1, totalTicks: 0, timestamp: 0)
        let now = CPUCounter(birth: 1, totalTicks: 24_000_000, timestamp: 1)
        XCTAssertEqual(CPUCounter.percent(previous: old, current: now,
            nanosecondsPerTick: 125.0 / 3.0)!, 100, accuracy: 0.0001)
    }
    func testConcurrentRenderersAreSummedBeforeAveraging() {
        var aggregates = CPUAggregates()
        aggregates.append(phase: "one", samples: [("renderer", 150), ("renderer", 0), ("main", 5)])
        aggregates.append(phase: "one", samples: [("renderer", 30), ("renderer", 10)])
        XCTAssertEqual(aggregates.values["one|renderer"], [150, 40])
        XCTAssertEqual(aggregates.values["one|main"], [5])
    }

    // Compare actual libproc ticks with getrusage's independently reported
    // seconds/microseconds, so a correct-looking synthetic test cannot hide
    // the platform-unit bug again.
    func testHostCPUTimeMatchesGetrusage() {
        func libproc() -> UInt64 {
            var value = rusage_info_v2()
            let result = withUnsafeMutableBytes(of: &value) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
            }
            XCTAssertEqual(result, 0)
            return value.ri_user_time + value.ri_system_time
        }
        func posixCPU() -> Double {
            var value = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &value), 0)
            return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
                + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        }
        let before = libproc(), referenceBefore = posixCPU()
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.15 {}
        let after = libproc(), referenceAfter = posixCPU()
        let converted = Double(after - before) * CPUCounter.nanosecondsPerTick / 1_000_000_000
        XCTAssertEqual(converted, referenceAfter - referenceBefore, accuracy: 0.01)
    }

}
