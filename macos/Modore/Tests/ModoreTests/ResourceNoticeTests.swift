import XCTest
@testable import Modore

final class ResourceNoticeTests: XCTestCase {
    private let gib: Int64 = 1_073_741_824

    private func snapshot(memory: Int = 2, cpu: Bool = false) -> HealthSnapshot {
        HealthSnapshot(date: Date(), freeBytes: 30 * gib, swapBytes: 0,
            memoryPressure: memory, thermalPressure: 0, processes: [
                .init(pid: 1, name: "CPU-leader", cpu: 150, residentBytes: 100, workspace: nil, cpuMeasured: true),
                .init(pid: 2, name: "Memory-leader", cpu: 1, residentBytes: 1000, workspace: nil,
                      physicalFootprintBytes: UInt64(4 * gib), cpuMeasured: true),
                .init(pid: 3, name: "Unmeasured", cpu: 999, residentBytes: nil, workspace: nil, cpuMeasured: false)
            ], cpuElevated: cpu)
    }

    func testMemoryWarningDoesNotBlameCPULeader() {
        let notice = ResourceNotice.health(snapshot(), notifyStorage: false)
        XCTAssertEqual(notice.route, "memory")
        XCTAssertTrue(notice.body.contains("Memory-leader"))
        XCTAssertFalse(notice.body.contains("CPU-leader"))
        XCTAssertFalse(notice.body.contains("Unmeasured"))
        XCTAssertEqual(HealthResourceFocus.memory.sorted(snapshot().processes).map(\.pid), [2, 1, 3])
    }

    func testCPUWarningUsesMeasuredCPUAndItsOwnDestination() {
        let notice = ResourceNotice.health(snapshot(memory: 1, cpu: true), notifyStorage: false)
        XCTAssertEqual(notice.route, "cpu")
        XCTAssertTrue(notice.body.contains("CPU-leader"))
        XCTAssertFalse(notice.body.contains("Memory-leader"))
        XCTAssertFalse(notice.body.contains("Unmeasured"))
    }

    func testMemoryToolAccumulationUsesAppFamilyEvidence() {
        let tools = MemoryToolAccumulation(launchGroups: 4, processCount: 120, bytes: UInt64(5 * gib))
        let notice = ResourceNotice.health(snapshot(), notifyStorage: false, toolAccumulation: tools)
        XCTAssertEqual(notice.route, "memory")
        XCTAssertTrue(notice.title.contains("120"))
        XCTAssertTrue(notice.body.contains(HealthSnapshot.bytes(5 * gib)))
        XCTAssertFalse(notice.body.contains("Memory-leader"))
        XCTAssertEqual(ResourceNotice.health(snapshot(), notifyStorage: true, toolAccumulation: tools).route, "storage")
        XCTAssertEqual(ResourceNotice.health(snapshot(memory: 1, cpu: true), notifyStorage: false,
                                            toolAccumulation: tools).route, "cpu")
    }

    func testMissingMemoryDoesNotSubstituteCPU() {
        let source = snapshot()
        let missing = HealthSnapshot(date: source.date, freeBytes: source.freeBytes,
            swapBytes: nil, memoryPressure: 2, thermalPressure: 0,
            processes: [.init(pid: 1, name: "CPU-only", cpu: 150, residentBytes: nil, workspace: nil)], cpuElevated: false)
        let notice = ResourceNotice.health(missing, notifyStorage: false)
        XCTAssertEqual(notice.route, "memory")
        XCTAssertFalse(notice.body.contains("CPU-only"))
    }

    func testUnknownStateIsNotReportedAsRecovered() {
        var missing = snapshot(memory: 1)
        missing.cpuAvailable = false
        XCTAssertNotEqual(ResourceNotice.health(missing, notifyStorage: false).title,
                          ResourceNotice.health(snapshot(memory: 1), notifyStorage: false).title)
    }

    func testRecoveryShowsShortfallNotRawLogsOrNetGainAsCleanup() {
        let report = AutomaticCacheReport(date: Date(), before: 2 * gib, after: 17 * gib,
            evidence: "private/raw/path", outcomes: ["raw diagnostic"], receipts: ["/receipt"], finished: true)
        let notice = ResourceNotice.automaticRecovery(report)
        XCTAssertEqual(notice.route, "storage-result")
        XCTAssertTrue(notice.title.contains(HealthSnapshot.bytes(17 * gib)))
        XCTAssertTrue(notice.body.contains(HealthSnapshot.bytes(3 * gib)))
        XCTAssertFalse(notice.body.contains(HealthSnapshot.bytes(15 * gib)))
        XCTAssertFalse(notice.body.contains("raw"))
        XCTAssertFalse(notice.body.contains("/receipt"))
    }

    func testInterruptedAndUnmeasuredRecoveryNeverClaimGoalReached() {
        let success = AutomaticCacheReport(date: Date(), before: gib, after: 30 * gib, evidence: "", finished: true)
        var interrupted = success
        interrupted.finished = false
        var unmeasured = success
        unmeasured.after = nil
        XCTAssertNotEqual(ResourceNotice.automaticRecovery(success).title, ResourceNotice.automaticRecovery(interrupted).title)
        XCTAssertNotEqual(ResourceNotice.automaticRecovery(success).title, ResourceNotice.automaticRecovery(unmeasured).title)
    }
}
