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
        let value = result(frames: [frame(cpu: nil, interval: 0), frame(cpu: 100, interval: 1), frame(cpu: 20, interval: 3)])
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
        let complete = result(frames: [frame(cpu: 100)], events: [start, .init(seconds: 1, kind: "auto-finished", detail: "cleanup")])
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

    func testInvalidCounterIntervalsAndCounterResetsRemainUnknown() {
        let before = CPUProcessCounter(pid: 1, started: 1, name: "fixture", nanoseconds: 1_000_000_000)
        let after = CPUProcessCounter(pid: 1, started: 1, name: "fixture", nanoseconds: 3_000_000_000)
        XCTAssertEqual(NativeCPUReader.percent(before: before, after: after, elapsed: 1), 200)
        for elapsed in [0.0, -1, .nan, .infinity, 10.01] {
            XCTAssertNil(NativeCPUReader.percent(before: before, after: after, elapsed: elapsed))
        }
        XCTAssertNil(NativeCPUReader.percent(before: after, after: before, elapsed: 1))
        XCTAssertNil(NativeCPUReader.percent(before: nil, after: after, elapsed: 1))
        XCTAssertNil(NativeCPUReader.percent(before: before,
            after: .init(pid: 2, started: 1, name: "fixture", nanoseconds: 3_000_000_000), elapsed: 1))
    }

    func testSimultaneousMarkersCannotBeAttributedToOneAction() {
        let rows = (1...6).map { timed(Double($0), cpu: $0 <= 3 ? 30 : 215) }
        let value = result(frames: rows, events: [
            .init(seconds: 3, kind: "manual", detail: "first-input"),
            .init(seconds: 3, kind: "manual", detail: "stutter")])
        XCTAssertTrue(value.actionAssessments.allSatisfy(\.otherActionOverlaps))
        XCTAssertFalse(value.actionAssessments.contains(where: \.rose))
    }

    func testStackOverlapUsesMatchingTerminalEvent() {
        let rows = (1...10).map { timed(Double($0), cpu: $0 <= 7 ? 30 : 215) }
        let events: [DiagnosticEvent] = [
            .init(seconds: 1, kind: "stack-start", detail: "sample", stackID: 0),
            .init(seconds: 3, kind: "stack-saved", detail: "saved", stackID: 0),
            .init(seconds: 7, kind: "manual", detail: "first-input")]
        XCTAssertFalse(result(frames: rows, events: events).actionAssessments[0].stacksOverlap)
        var unmatched = events
        unmatched[1] = .init(seconds: 3, kind: "stack-saved", detail: "other sample", stackID: 1)
        XCTAssertTrue(result(frames: rows, events: unmatched).actionAssessments[0].stacksOverlap)
    }

    func testPartialCoverageAndUnfinishedReplayAreExplicit() {
        let value = result(frames: [frame(cpu: nil, interval: 0, missing: 1), frame(cpu: 40, missing: 1)],
            events: [.init(seconds: 1, kind: "auto-start", detail: "first-input")])
        XCTAssertTrue(value.incomplete)
        XCTAssertTrue(value.coverageDescription.contains("누락 표본 1개"))
        XCTAssertTrue(value.report.contains("실제 부하보다 낮을 수"))
        XCTAssertFalse(value.replayCompleted)
        XCTAssertNotNil(value.comparisonWarning(value))
        XCTAssertTrue(value.report.contains("입력 처리 시간과 입력→프레임 지연은 수집하지 않습니다"))
    }

    private func sleepingTarget() throws -> (Process, DiagnosticTarget) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["20"]
        try process.run()
        let counter = try XCTUnwrap(NativeCPUReader.read(process.processIdentifier))
        return (process, .init(pid: counter.pid, birth: counter.started, name: "Sleep fixture", bundleID: "app.fixture.sleep", version: "1"))
    }

    private func evidenceRoot() -> URL {
        let path = ProcessInfo.processInfo.environment["MODORE_DIAGNOSTIC_EVIDENCE"]
        return path.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-runtime-" + UUID().uuidString)
    }

    func testRuntimeStackCancellationAndTargetExitRetainPartialResult() async throws {
        let (process, target) = try sleepingTarget()
        defer { if process.isRunning { process.terminate() } }
        let root = evidenceRoot()
        defer { if ProcessInfo.processInfo.environment["MODORE_DIAGNOSTIC_EVIDENCE"] == nil { try? FileManager.default.removeItem(at: root) } }
        let recorder = try AppDiagnosticRecorder(target: target, condition: "cancel fixture", root: root)
        _ = await recorder.capture()
        let pressed = NativeCPUReader.continuousSeconds
        try await Task.sleep(nanoseconds: 100_000_000)
        await recorder.mark("manual", "stutter", at: pressed)
        _ = await recorder.capture()
        let message = await recorder.collectStack()
        XCTAssertTrue(message.contains("시작"))
        let saved = try await recorder.finish("fixture cancel")
        XCTAssertLessThan(saved.events[0].seconds, saved.frames[1].seconds - 0.05)
        let start = try XCTUnwrap(saved.events.first { $0.kind == "stack-start" })
        let partial = try XCTUnwrap(saved.events.first { $0.kind == "stack-partial" })
        let samplerPID = try XCTUnwrap(start.samplerPID)
        for _ in 0..<20 {
            if kill(samplerPID, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(kill(samplerPID, 0), -1, "Cancelled native sampler must actually exit")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(start.stackID, partial.stackID)
        XCTAssertEqual(start.stackFile, partial.stackFile)
        let folder = await recorder.folder
        let disk = try JSONDecoder().decode(DiagnosticResult.self, from: Data(contentsOf: folder.appendingPathComponent("result.json")))
        XCTAssertEqual(disk.schemaVersion, 4)
        XCTAssertEqual(disk.events.count, saved.events.count)
        let presentation = DiagnosticPresentation(disk)
        XCTAssertFalse(presentation.headline.isEmpty)
        XCTAssertEqual(presentation.actions.count, 1)
        let stopped = await recorder.capture()
        XCTAssertNil(stopped.0)
        let exited = try AppDiagnosticRecorder(target: target, condition: "exit fixture", root: root)
        _ = await exited.capture()
        process.terminate(); process.waitUntilExit()
        let ended = await exited.capture()
        XCTAssertNil(ended.0)
        XCTAssertEqual(ended.1, "대상 앱 종료 또는 재시작")
        _ = try await exited.finish(try XCTUnwrap(ended.1))
    }

    func testRuntimeCompletedStackHasFileAndActualTerminalTimestamp() async throws {
        let (process, target) = try sleepingTarget()
        defer { if process.isRunning { process.terminate() } }
        let root = evidenceRoot()
        defer { if ProcessInfo.processInfo.environment["MODORE_DIAGNOSTIC_EVIDENCE"] == nil { try? FileManager.default.removeItem(at: root) } }
        let recorder = try AppDiagnosticRecorder(target: target, condition: "saved stack fixture", root: root)
        _ = await recorder.capture()
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = await recorder.capture()
        _ = await recorder.collectStack()
        for _ in 0..<9 {
            try await Task.sleep(nanoseconds: 500_000_000)
            _ = await recorder.capture()
        }
        let saved = try await recorder.finish("fixture complete")
        let start = try XCTUnwrap(saved.events.first { $0.kind == "stack-start" })
        let end = try XCTUnwrap(saved.events.first { $0.kind == "stack-saved" })
        XCTAssertEqual(start.stackID, end.stackID)
        XCTAssertEqual(start.stackFile, end.stackFile)
        XCTAssertLessThan(end.seconds - start.seconds, 6)
        let folder = await recorder.folder
        let path = folder.appendingPathComponent("native-private").appendingPathComponent(try XCTUnwrap(end.stackFile))
        XCTAssertGreaterThan(try Data(contentsOf: path).count, 0)
        XCTAssertFalse(saved.incomplete)
    }

    func testRecorderIntegratedCPUAgainstChildGetrusage() async throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", "import sys,time,resource\nprint('ready',flush=True)\nsys.stdin.readline()\nr=resource.getrusage(resource.RUSAGE_SELF); before=r.ru_utime+r.ru_stime\nt=time.process_time()\nwhile time.process_time()-t<0.25: pass\nr=resource.getrusage(resource.RUSAGE_SELF)\nprint(r.ru_utime+r.ru_stime-before,flush=True)\nsys.stdin.readline()"]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        func line() throws -> String {
            var data = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte == Data([10]) { break }; data.append(byte)
            }
            return String(decoding: data, as: UTF8.self)
        }
        XCTAssertEqual(try line(), "ready")
        let counter = try XCTUnwrap(NativeCPUReader.read(process.processIdentifier))
        let root = evidenceRoot()
        defer { if ProcessInfo.processInfo.environment["MODORE_DIAGNOSTIC_EVIDENCE"] == nil { try? FileManager.default.removeItem(at: root) } }
        let recorder = try AppDiagnosticRecorder(target: .init(pid: counter.pid, birth: counter.started, name: "CPU fixture", bundleID: "app.fixture.cpu", version: "1"), condition: "getrusage reference", root: root)
        _ = await recorder.capture()
        try input.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))
        let reference = try XCTUnwrap(Double(try line()))
        let (frame, reason) = await recorder.capture()
        XCTAssertNil(reason)
        let measured = try XCTUnwrap(frame)
        XCTAssertEqual(try XCTUnwrap(measured.targetCPU) * measured.interval / 100, reference, accuracy: 0.025)
        let saved = try await recorder.finish("fixture reference")
        let folder = await recorder.folder
        let evidence: [String: Double] = ["getrusageCPUSeconds": reference, "recordedCPUSeconds": try XCTUnwrap(saved.meanCPU) * measured.interval / 100,
            "collectorMilliseconds": measured.collectionMilliseconds, "observerCPUPercent": measured.observerCPU ?? -1]
        try JSONEncoder().encode(evidence).write(to: folder.appendingPathComponent("reference.json"))
    }

    func testMarkerLimitIsReportedAndLeavesRoomForStackEvidence() async throws {
        let current = try XCTUnwrap(NativeCPUReader.read(getpid()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-limit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AppDiagnosticRecorder(target: .init(pid: getpid(), birth: current.started, name: "fixture", bundleID: "app.fixture", version: "1"), condition: "", root: root)
        for _ in 0..<(DiagnosticBudget.events - DiagnosticBudget.stacks * 2) {
            let accepted = await recorder.mark("manual", "stutter")
            XCTAssertTrue(accepted)
        }
        let rejected = await recorder.mark("manual", "stutter")
        XCTAssertFalse(rejected)
        let terminal = await recorder.mark("stack-partial", "fixture", stackID: 0, stackFile: "stack-0.txt")
        XCTAssertTrue(terminal)
        _ = try await recorder.finish("fixture")
        let afterFinish = await recorder.mark("manual", "stutter")
        XCTAssertFalse(afterFinish)
    }
}
