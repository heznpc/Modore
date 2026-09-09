import Darwin
import Foundation
import XCTest
@testable import Modore

final class CPUWatchTests: XCTestCase {
    private func sample(_ time: Double, thermal: Int = 0, counters: [CPUProcessCounter] = []) -> CPUSample {
        CPUSample(uptime: time, counters: counters, thermalPressure: thermal, cores: 8)
    }

    func testCPUTimeDeltaIgnoresPIDReuseAndSleepGap() {
        let before = sample(10, counters: [.init(pid: 42, started: 1, name: "worker", nanoseconds: 1_000_000_000)])
        let after = sample(20, counters: [.init(pid: 42, started: 1, name: "worker", nanoseconds: 21_000_000_000)])
        XCTAssertEqual(after.usage(since: before).first?.percent, 200)
        XCTAssertTrue(sample(20, counters: [.init(pid: 42, started: 2, name: "new", nanoseconds: 21_000_000_000)])
            .usage(since: before).isEmpty)
        XCTAssertTrue(sample(50, counters: after.counters).usage(since: before).isEmpty)
    }

    func testBriefBurstNeverAlertsAndSustainedLoadHasTenMinuteCooldown() {
        var policy = CPUAlertPolicy()
        let high = [CPUProcessUsage(pid: 1, name: "worker", percent: 200)]
        XCTAssertFalse(policy.evaluate(usage: high, sample: sample(0)))
        XCTAssertFalse(policy.evaluate(usage: [], sample: sample(50)))
        XCTAssertFalse(policy.evaluate(usage: high, sample: sample(60)))
        XCTAssertFalse(policy.evaluate(usage: high, sample: sample(119)))
        XCTAssertTrue(policy.evaluate(usage: high, sample: sample(120)))
        XCTAssertFalse(policy.evaluate(usage: [], sample: sample(130)))
        XCTAssertFalse(policy.evaluate(usage: high, sample: sample(140)))
        XCTAssertFalse(policy.evaluate(usage: high, sample: sample(719)))
        XCTAssertTrue(policy.evaluate(usage: high, sample: sample(720)))
    }

    func testAggregateLoadAndThermalPressureDetectDistributedWork() {
        let medium = (1...8).map { CPUProcessUsage(pid: Int32($0), name: "worker", percent: 75) }
        var policy = CPUAlertPolicy()
        XCTAssertFalse(policy.evaluate(usage: medium, sample: sample(0)))
        XCTAssertTrue(policy.evaluate(usage: medium, sample: sample(60)))
        policy = CPUAlertPolicy()
        let low = [CPUProcessUsage(pid: 1, name: "worker", percent: 30)]
        XCTAssertFalse(policy.evaluate(usage: low, sample: sample(0)))
        XCTAssertFalse(policy.evaluate(usage: low, sample: sample(60, thermal: 1)))
        XCTAssertTrue(policy.evaluate(usage: low, sample: sample(120, thermal: 1)))
    }

    func testSystemProcessesSupplementRestrictedPIDsWithoutDoubleCounting() {
        let rows = CPUSample.parseSystemProcesses("445 42.5 /System/WindowServer\n42 80 /Applications/Google Chrome Helper\n9 nan bad\n")
        XCTAssertEqual(rows.map(\.name), ["WindowServer", "Google Chrome Helper"])
        var after = sample(20, counters: [.init(pid: 42, started: 1, name: "native", nanoseconds: 21_000_000_000)])
        after.systemProcesses = rows
        let before = sample(10, counters: [.init(pid: 42, started: 1, name: "native", nanoseconds: 1_000_000_000)])
        let usage = after.usage(since: before)
        XCTAssertEqual(usage.map(\.pid), [42, 445])
        XCTAssertEqual(usage.map(\.percent), [200, 42.5])
    }

    func testSystemReaderRunsThroughBoundedProcessRunner() async {
        let observed = await CPUSample.captureWithSystemProcesses()
        XCTAssertFalse(observed.systemProcesses.isEmpty)
        XCTAssertTrue(observed.systemProcesses.contains { $0.pid == getpid() })
    }

    func testNativeSamplerMeasuresActualCPUTimeForThisProcess() {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let posixBefore = cpuSeconds()
        let before = CPUSample.capture()
        let until = ProcessInfo.processInfo.systemUptime + 0.15
        while ProcessInfo.processInfo.systemUptime < until { _ = UUID().uuidString }
        let after = CPUSample.capture()
        let own = after.usage(since: before).first { $0.pid == getpid() }
        XCTAssertNotNil(own)
        let expectedSeconds = cpuSeconds() - posixBefore
        let measuredSeconds = (own?.percent ?? 0) * (after.uptime - before.uptime) / 100
        // Comparing with independent POSIX units catches the ARM Mach tick / ns mismatch.
        XCTAssertEqual(measuredSeconds, expectedSeconds, accuracy: max(0.03, expectedSeconds * 0.3))
        XCTAssertGreaterThan(own?.percent ?? 0, 1)
        XCTAssertFalse(own?.name.isEmpty ?? true)
    }
}
