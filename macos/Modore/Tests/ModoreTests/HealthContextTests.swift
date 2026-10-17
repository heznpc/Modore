import XCTest
@testable import Modore

final class HealthContextTests: XCTestCase {
    private func sample(_ time: Double, free: Int64? = 30 * 1_073_741_824, pressure: Int? = 1, swap: UInt64 = 0) -> HealthSnapshot {
        HealthSnapshot(date: Date(timeIntervalSince1970: time), freeBytes: free, swapBytes: swap,
                       memoryPressure: pressure, thermalPressure: 0,
                       processes: [.init(pid: 1, name: "test", cpu: 1, residentBytes: 100, workspace: nil)], cpuElevated: false)
    }
    func testRecoveryNeedsCompleteHealthyMinuteAndUnknownResetsIt() {
        var journal = HealthJournal()
        XCTAssertTrue(journal.observe(sample(0, free: 2_000_000_000)))
        XCTAssertFalse(journal.observe(sample(10)))
        XCTAssertFalse(journal.observe(sample(65, pressure: nil)))
        XCTAssertFalse(journal.observe(sample(70)))
        XCTAssertFalse(journal.observe(sample(129)))
        XCTAssertTrue(journal.observe(sample(130)))
        XCTAssertNotNil(journal.incidents.first?.resolvedAt)
    }
    func testRestartNeverClaimsRecoveryAndKeepsPriorAction() throws {
        var journal = HealthJournal()
        journal.observe(sample(0, pressure: 2))
        journal.markAction("작업 확인", snapshot: sample(5, pressure: 2))
        var restored = try JSONDecoder().decode(HealthJournal.self, from: JSONEncoder().encode(journal))
        restored.resume()
        restored.observe(sample(100))
        XCTAssertTrue(restored.incidents[0].interrupted)
        XCTAssertNil(restored.incidents[0].resolvedAt)
        XCTAssertEqual(restored.incidents[0].action, "작업 확인")
    }
    func testRepeatedWarningsDoNotCreateUnboundedHistoryAndEscalationIsReported() {
        var journal = HealthJournal()
        XCTAssertTrue(journal.observe(sample(0, free: 10_000_000_000)))
        for index in 1...100 { XCTAssertFalse(journal.observe(sample(Double(index), free: 10_000_000_000))) }
        XCTAssertEqual(journal.incidents.count, 1)
        XCTAssertTrue(journal.observe(sample(101, free: 1_000_000_000, pressure: 2)))
        XCTAssertEqual(journal.incidents.count, 1)
        for index in 1...50 { journal.resume(); journal.observe(sample(Double(index + 200), pressure: 2)) }
        XCTAssertEqual(journal.incidents.count, 40)
    }
    func testSwapCorrelationRequiresObservedIncrease() {
        let before = sample(0, free: 10_000_000_000, swap: 1_000_000_000)
        let after = sample(60, free: 8_000_000_000, swap: 3_000_000_000)
        XCTAssertTrue(after.explanation(from: before).contains("가능성"))
        XCTAssertFalse(before.explanation(from: after).contains("함께 관찰"))
    }
    func testShortCPUBurstIsRecordedAndPeakSurvivesRecoverySamples() throws {
        var journal = HealthJournal()
        journal.observe(sample(0, pressure:2))
        var burst = HealthSnapshot(date:Date(timeIntervalSince1970:2),freeBytes:30_000_000_000,swapBytes:0,memoryPressure:2,thermalPressure:0,processes:[.init(pid:42,name:"renderer",cpu:430,residentBytes:100,workspace:nil)],cpuElevated:false)
        burst.cpuBurst=true
        XCTAssertTrue(burst.issues.contains("CPU 순간 부하"))
        XCTAssertTrue(journal.observe(burst))
        journal.observe(sample(4,pressure:2))
        XCTAssertEqual(journal.incidents.first?.cpuPeak?.processes.first?.pid,42)
        XCTAssertEqual(journal.incidents.first?.cpuPeak?.peakCPU,430)
        let restored=try JSONDecoder().decode(HealthJournal.self,from:JSONEncoder().encode(journal))
        XCTAssertEqual(restored.incidents.first?.cpuPeak?.peakCPU,430)
    }
    func testOldSnapshotsDecodeWithoutBurstField() throws {
        let old=try JSONEncoder().encode(sample(0))
        let decoded=try JSONDecoder().decode(HealthSnapshot.self,from:old)
        XCTAssertNil(decoded.cpuBurst)
        XCTAssertFalse(decoded.issues.contains("CPU 순간 부하"))
    }
    func testHealthRouteRejectsUntrustedParameters() {
        XCTAssertEqual(ModoreRoute(url: URL(string: "modore://health")!), .health)
        XCTAssertNil(ModoreRoute(url: URL(string: "modore://health?execute=1")!))
    }
    func testCaptureKeepsUnmeasuredCPUSeparateFromMemoryFootprint() {
        let cpu = CPUSample(uptime: 1,
            counters: [.init(pid: 12345, started: 1, name: "new process", nanoseconds: 0,
                             residentBytes: 1_000, physicalFootprintBytes: 2_000)],
            thermalPressure: 0, cores: 8, enumeratedProcessCount: 2)
        let captured = HealthSnapshot.capture(sample: cpu, usage: [], cpuElevated: false)
        XCTAssertFalse(captured.cpuAvailable)
        XCTAssertEqual(captured.processes.first?.cpuMeasured, false)
        XCTAssertEqual(captured.processes.first?.residentBytes, 1_000)
        XCTAssertEqual(captured.processes.first?.physicalFootprintBytes, 2_000)
        XCTAssertEqual(captured.cpuCoverage?.unavailableProcesses, 2)
        XCTAssertNotNil(captured.compressedBytes)
    }

    func testFreshnessRejectsOldAndFutureSnapshots() {
        let value = sample(100)
        XCTAssertTrue(value.isFresh(at: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(value.isFresh(at: Date(timeIntervalSince1970: 130)))
        XCTAssertFalse(value.isFresh(at: Date(timeIntervalSince1970: 131)))
        XCTAssertFalse(value.isFresh(at: Date(timeIntervalSince1970: 99)))
    }

    func testLegacySnapshotsWithoutPlatformFieldsStillDecode() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample(0))) as? [String: Any])
        for key in ["storageCapacity", "compressedBytes", "cpuCoverage", "power", "connectivity", "cpuBurst"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(HealthSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.storageCapacity)
        XCTAssertNil(decoded.compressedBytes)
        XCTAssertNil(decoded.cpuCoverage)
        XCTAssertNil(decoded.power)
        XCTAssertNil(decoded.connectivity)
        XCTAssertNil(decoded.processes.first?.cpuMeasured)
    }

    func testBatteryPercentageDoesNotInventZeroOrDesktopBattery() {
        XCTAssertEqual(PowerSnapshot.percentage(current: 40, maximum: 80), 50)
        XCTAssertEqual(PowerSnapshot.percentage(current: 0, maximum: 100), 0)
        XCTAssertNil(PowerSnapshot.percentage(current: nil, maximum: nil))
        XCTAssertNil(PowerSnapshot.percentage(current: 10, maximum: 0))
        XCTAssertNil(PowerSnapshot.percentage(current: -1, maximum: 100))
        XCTAssertNil(PowerSnapshot.percentage(current: 110, maximum: 100))
        let power = PowerSourceReader.capture()
        if power.hasBattery == false { XCTAssertNil(power.batteryPercent) }
    }

}
