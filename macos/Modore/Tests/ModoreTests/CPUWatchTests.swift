import Darwin
import Foundation
import XCTest
@testable import Modore

final class CPUWatchTests: XCTestCase {
    func testBackgroundSamplingSlowsDownAndExpensiveCollectionGetsRecoveryTime() {
        XCTAssertEqual(CPUSamplingCadence.delay(visible: false, thermalPressure: 0, collectionSeconds: 0.01), 10)
        XCTAssertEqual(CPUSamplingCadence.delay(visible: true, thermalPressure: 0, collectionSeconds: 0.01), 2)
        XCTAssertEqual(CPUSamplingCadence.delay(visible: true, thermalPressure: 2, collectionSeconds: 0.01), 20)
        XCTAssertEqual(CPUSamplingCadence.delay(visible: true, thermalPressure: 0, collectionSeconds: 0.15), 14.85, accuracy: 0.001)
        XCTAssertEqual(CPUSamplingCadence.delay(visible: false, thermalPressure: 0, collectionSeconds: 2), 20)
    }

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

    func testProtectedAndNewProcessesRemainUnavailableInsteadOfUsingDifferentCPUWindow() {
        var after = sample(20, counters: [
            .init(pid: 42, started: 1, name: "native", nanoseconds: 21_000_000_000),
            .init(pid: 43, started: 2, name: "new", nanoseconds: 10_000_000)
        ])
        after.enumeratedProcessCount = 3 // one protected PID and one new process
        let before = sample(10, counters: [.init(pid: 42, started: 1, name: "native", nanoseconds: 1_000_000_000)])
        let usage = after.usage(since: before)
        XCTAssertEqual(usage.map(\.pid), [42])
        XCTAssertEqual(usage.map(\.percent), [200])
        let coverage = after.coverage(measuredCount: usage.count)
        XCTAssertEqual(coverage.measuredProcesses, 1)
        XCTAssertEqual(coverage.unavailableProcesses, 2)
        XCTAssertTrue(coverage.isPartial)
        XCTAssertTrue(sample(0).coverage(measuredCount: 0).isPartial)
    }

    func testNativeCaptureReportsCoverageAndPhysicalFootprint() async {
        let observed = await CPUSample.captureWithSystemProcesses()
        XCTAssertGreaterThan(observed.enumeratedProcessCount ?? 0, 0)
        let own = observed.counters.first { $0.pid == getpid() }
        XCTAssertNotNil(own)
        XCTAssertGreaterThan(own?.physicalFootprintBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(observed.enumeratedProcessCount ?? 0, observed.counters.count)
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
