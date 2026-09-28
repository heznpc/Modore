import XCTest
import Darwin
@testable import Modore

final class AppDiagnosticTests: XCTestCase {
    private var target: DiagnosticTarget { .init(pid: 1, birth: 1, name: "Fixture", bundleID: "app.fixture", version: "1") }
    private func frame(cpu: Double?, interval: Double = 1, missing: Int = 0) -> DiagnosticFrame {
        .init(seconds: 1, interval: interval, targetCPU: cpu, observerCPU: 1, samplerCPU: nil,
              residentBytes: 1024, available: cpu == nil ? 0 : 1, unavailable: missing, collectionMilliseconds: 1, thermal: 0)
    }
    private func result(frames: [DiagnosticFrame], events: [DiagnosticEvent] = []) -> DiagnosticResult {
        .init(id: UUID(), target: target, condition: "private-note-DO-NOT-SHARE", started: Date(), frames: frames, events: events,
              finishReason: "test", timebaseNumer: 125, timebaseDenom: 3, schemaVersion: 1)
    }
    func testTimeWeightedCPUAndMissingData() {
        let value = result(frames: [frame(cpu: nil), frame(cpu: 100, interval: 1), frame(cpu: 20, interval: 3)])
        XCTAssertEqual(value.meanCPU, 40)
        XCTAssertEqual(value.peakCPU, 100)
        XCTAssertFalse(value.incomplete)
        XCTAssertNil(result(frames: [frame(cpu: nil)]).meanCPU)
        XCTAssertTrue(result(frames: [frame(cpu: nil)]).incomplete)
        XCTAssertTrue(result(frames: [frame(cpu: 10), frame(cpu: nil)]).incomplete)
    }
    func testReportSeparatesRendererAndPreservesOldFrameDecoding() throws {
        var measured = frame(cpu: 400)
        measured.rendererCPU = 100
        measured.topProcesses = [.init(pid: 2, name: "worker", cpu: 300), .init(pid: 3, name: "Renderer", cpu: 100)]
        let report = result(frames: [measured])
        XCTAssertEqual(report.meanRendererCPU, 100)
        XCTAssertTrue(report.report.contains("worker"))
        let old = try JSONEncoder().encode(frame(cpu: 20))
        let decoded = try JSONDecoder().decode(DiagnosticFrame.self, from: old)
        XCTAssertNil(decoded.rendererCPU)
        XCTAssertEqual(decoded.targetCPU, 20)
    }
    func testComparisonRejectsDifferentOrInterruptedActions() {
        let start = DiagnosticEvent(seconds: 0, kind: "auto-start", detail: "first-input")
        let complete = result(frames: [frame(cpu: 100)], events: [start])
        XCTAssertNil(complete.comparisonWarning(complete))
        XCTAssertNotNil(complete.comparisonWarning(result(frames: [frame(cpu: 100)])))
        XCTAssertNotNil(complete.comparisonWarning(result(frames: [frame(cpu: 100)], events: [start, .init(seconds: 1, kind: "auto-stopped", detail: "stop")])))
        XCTAssertFalse(complete.report.contains("private-note-DO-NOT-SHARE"))
    }
    func testBudgetBacksOffWhenCollectionExpensiveOrHot() {
        XCTAssertEqual(DiagnosticBudget.delay(collectionSeconds: 0.001, thermal: 0), 0.5)
        XCTAssertGreaterThanOrEqual(DiagnosticBudget.delay(collectionSeconds: 0.1, thermal: 0), 4.9)
        XCTAssertGreaterThanOrEqual(DiagnosticBudget.delay(collectionSeconds: 0, thermal: 2), 2)
    }
    private func timed(_ seconds: Double, cpu: Double, renderer: Double? = nil, missing: Int = 0, interval: Double = 1) -> DiagnosticFrame {
        .init(seconds: seconds, interval: interval, targetCPU: cpu, observerCPU: 1, samplerCPU: nil,
              residentBytes: 0, available: 1, unavailable: missing, collectionMilliseconds: 1, thermal: 0,
              rendererCPU: renderer)
    }
    func testActionAnalysisFindsRecordedRiseWithoutClaimingInputLatency() {
        let rows = (1...6).map { timed(Double($0), cpu: $0 <= 3 ? 30 : 215) }
        let value = result(frames: rows, events: [.init(seconds: 3, kind: "manual", detail: "first-input")])
        let action = value.actionAssessments[0]
        XCTAssertTrue(action.rose)
        XCTAssertEqual(action.before.mean, 30)
        XCTAssertEqual(action.after.mean, 215)
        XCTAssertTrue(value.report.contains("입력 지연 시간이나 인과관계를 증명하지 않습니다"))
        XCTAssertTrue(value.report.contains("프로세스별 CPU를 저장하지 않아"))
    }
    func testMissingBaselineStillReportsObservedHighCPUButNotIncrease() {
        let rows = (1...6).map { timed(Double($0), cpu: $0 <= 3 ? 30 : 215, missing: $0 == 2 ? 1 : 0) }
        let value = result(frames: rows, events: [.init(seconds: 3, kind: "manual", detail: "first-input")])
        XCTAssertTrue(value.actionAssessments[0].highCPU)
        XCTAssertFalse(value.actionAssessments[0].rose)
        XCTAssertTrue(value.diagnosticHeadline.contains("높은 CPU"))
    }
    func testBoundaryCrossingAndShortObservationCannotBecomeActionEvidence() {
        let rows = [timed(2, cpu: 20), timed(3.5, cpu: 400), timed(4, cpu: 10, interval: 0.5)]
        let action = result(frames: rows, events: [.init(seconds: 3, kind: "manual", detail: "sidebar")]).actionAssessments[0]
        XCTAssertEqual(action.after.mean, 10)
        XCTAssertFalse(action.after.complete)
        XCTAssertFalse(action.highCPU)
        XCTAssertFalse(action.rose)
    }
    func testWorkerLoadIsNotAttributedToRendererAndStackCollectionConfoundsIncrease() {
        let rows = (1...6).map { timed(Double($0), cpu: 400, renderer: 10) }
        let marker = DiagnosticEvent(seconds: 3, kind: "manual", detail: "attachment")
        let value = result(frames: rows, events: [marker])
        XCTAssertFalse(value.actionAssessments[0].highCPU)
        XCTAssertEqual(value.actionAssessments[0].after.mean, 10)
        XCTAssertTrue(value.diagnosticHeadline.contains("앱·작업 합산"))
        let high = (1...6).map { timed(Double($0), cpu: $0 <= 3 ? 30 : 215) }
        let sampled = result(frames: high, events: [marker, .init(seconds: 4, kind: "stack-start", detail: "sample")])
        XCTAssertFalse(sampled.actionAssessments[0].rose)
        XCTAssertTrue(sampled.actionAssessments[0].stacksOverlap)
        let overlap = result(frames: high, events: [marker, .init(seconds: 4, kind: "manual", detail: "sidebar")])
        XCTAssertFalse(overlap.actionAssessments[0].rose)
    }
    func testAutomaticStacksAreBoundedAndPreferBusyRendererOverWorker() {
        var spike = timed(40, cpu: 600, renderer: 200)
        spike.topProcesses = [.init(pid: 2, name: "worker", cpu: 400), .init(pid: 3, name: "App Renderer", cpu: 200)]
        XCTAssertEqual(DiagnosticSpikePolicy.target(frame: spike, count: 0, lastAttempt: 0, sampling: false), 3)
        XCTAssertNil(DiagnosticSpikePolicy.target(frame: spike, count: 2, lastAttempt: 0, sampling: false))
        XCTAssertNil(DiagnosticSpikePolicy.target(frame: spike, count: 0, lastAttempt: 20, sampling: false))
        XCTAssertNil(DiagnosticSpikePolicy.target(frame: spike, count: 0, lastAttempt: 0, sampling: true))
        XCTAssertNil(DiagnosticSpikePolicy.target(frame: timed(40, cpu: 10), count: 0, lastAttempt: 0, sampling: false))
    }
    func testPIDReuseAndMonitoringGapAreNotValidCPU() {
        let a = CPUProcessCounter(pid: 1, started: 1, name: "test", nanoseconds: 0)
        let b = CPUProcessCounter(pid: 1, started: 1, name: "test", nanoseconds: 1_000_000_000)
        XCTAssertEqual(NativeCPUReader.percent(before: a, after: b, elapsed: 1), 100)
        XCTAssertNil(NativeCPUReader.percent(before: a, after: b, elapsed: 30))
        XCTAssertNil(NativeCPUReader.percent(before: a, after: .init(pid: 1, started: 2, name: "reuse", nanoseconds: 1_000_000_000), elapsed: 1))
    }
    func testNativeCountersAgainstOSGetrusage() throws {
        func cpu() -> Double {
            var value = rusage(); XCTAssertEqual(getrusage(RUSAGE_SELF, &value), 0)
            return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        }
        let before = try XCTUnwrap(NativeCPUReader.read(getpid()))
        let refBefore = cpu(), time = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - time < 0.1 {}
        let after = try XCTUnwrap(NativeCPUReader.read(getpid()))
        XCTAssertEqual(Double(after.nanoseconds - before.nanoseconds) / 1e9, cpu() - refBefore, accuracy: 0.01)
    }
    func testRecorderActuallyCapturesAndPersistsAndRejectsRestart() async throws {
        let current = try XCTUnwrap(NativeCPUReader.read(getpid()))
        let selected = DiagnosticTarget(pid: getpid(), birth: current.started, name: "Unit fixture", bundleID: "app.fixture", version: "1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modore-diagnostic-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AppDiagnosticRecorder(target: selected, condition: "fixture", root: root)
        _ = await recorder.capture()
        try await Task.sleep(nanoseconds: 100_000_000)
        let (frame, reason) = await recorder.capture()
        XCTAssertNil(reason); XCTAssertNotNil(frame?.targetCPU)
        await recorder.mark("manual", "first-input")
        let saved = try await recorder.finish("fixture-end")
        XCTAssertEqual(saved.frames.count, 2); XCTAssertEqual(saved.events.count, 1)
        let folder = await recorder.folder
        let disk = try JSONDecoder().decode(DiagnosticResult.self, from: Data(contentsOf: folder.appendingPathComponent("result.json")))
        XCTAssertEqual(disk.id, saved.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.md").path))
        let stopped = await recorder.capture(); XCTAssertNil(stopped.0)
        let reused = try AppDiagnosticRecorder(target: .init(pid: getpid(), birth: current.started + 1, name: "fixture", bundleID: "app.fixture", version: "1"), condition: "", root: root)
        let invalid = await reused.capture(); XCTAssertNotNil(invalid.1); XCTAssertNil(invalid.0)
        _ = try await reused.finish("test")
    }
}
