import Foundation
import XCTest
@testable import Modore

private actor InvestigationProbe {
    var previews = 0
    var executions = 0
    func preview() { previews += 1 }
    func execute() { executions += 1 }
    func counts() -> (Int, Int) { (previews, executions) }
}

@MainActor
final class StorageInvestigationTests: XCTestCase {
    private func item(_ id: String = "pip_cache", path: String = "/example/cache") -> StorageItem {
        StorageItem(json: ["kind": "cache", "cleanupId": id, "path": path,
            "label": "Cache", "sizeGB": 1, "measureStatus": "timed_out"])!
    }
    private func response(status: String = "ready", reason: String = "", processes: String = "",
                          id: String = "pip_cache", exit: Int32 = 0) -> CapturedProcessResult {
        CapturedProcessResult(status: exit, output: """
        version\t1
        operation\tpreview
        recipeId\t\(id)
        status\t\(status)
        estimateMeasured\t\(status == "ready" ? "true" : "false")
        accountingVersion\t2
        estimatedBytes\t1048576
        processNote\t작업을 먼저 종료하세요
        usageEvidence\t\(status == "ready" ? "대상·관련 프로세스 검사 통과 · 미사용 확정 아님" : "")
        regenerationEvidence\t명세 확인 · 재빌드 미검증
        blockedReason\t\(reason)
        runningProcesses\t\(processes)
        approvalToken\t\(String(repeating: "a", count: 64))
        approvalExpiresEpoch\t\(Int(Date().addingTimeInterval(600).timeIntervalSince1970))
        target\t/example/cache
        """, endState: .exited, outputTruncated: false)
    }

    func testUnmeasuredInventoryRequiresInvestigationAndDoesNotInferUnused() {
        XCTAssertEqual(StorageInvestigation.judgment(for: item(), evidence: nil), .uncertain)
        let evidence = StorageInvestigation.evidence(item: item(), result: response())
        XCTAssertEqual(evidence.judgment, .ready)
        XCTAssertEqual(evidence.bytes, 1_048_576)
        XCTAssertTrue(evidence.usage.contains("미사용 확정 아님"))
        XCTAssertFalse(evidence.usage.contains("먼저 종료"))
        XCTAssertTrue(evidence.impact.contains("먼저 종료"))
        XCTAssertTrue(evidence.regeneration.contains("재빌드 미검증"))
    }

    func testUnknownProcessLocationIsUncertainRatherThanInUse() {
        let evidence = StorageInvestigation.evidence(item: item(), result: response(status: "blocked",
            reason: "사용 여부 미확인 항목입니다. 프로세스 위치를 확인하지 못했습니다.", processes: "swift (사용 여부 미확인)"))
        XCTAssertEqual(evidence.judgment, .uncertain)
        XCTAssertEqual(evidence.issue, .usage)
        let active = StorageInvestigation.evidence(item: item(), result: response(status: "blocked",
            reason: "관련 작업을 종료하세요", processes: "swift PID 123"))
        XCTAssertEqual(active.judgment, .inUse)
    }

    func testFailuresHaveSpecificRecoveryPathsAndNoMeasuredPlaceholder() {
        let timeout = StorageInvestigation.evidence(item: item(), result: nil)
        XCTAssertEqual(timeout.issue, .timedOut)
        XCTAssertNil(timeout.bytes)
        let denied = StorageInvestigation.evidence(item: item(), result: response(status: "blocked", reason: "접근 권한이 없습니다"))
        XCTAssertEqual(denied.issue, .access)
        XCTAssertNil(denied.bytes)
        let mismatch = StorageInvestigation.evidence(item: item(), result: response(id: "npm_cache"))
        XCTAssertEqual(mismatch.judgment, .uncertain)
        let failed = StorageInvestigation.evidence(item: item(), result: response(exit: 1))
        XCTAssertNotEqual(failed.judgment, .ready)
    }

    func testMissingPathIsNotPresentedAsFailedMeasurement() {
        let absent = StorageInvestigation.evidence(item: item(), result: response(status: "blocked"), pathMissing: true)
        XCTAssertEqual(absent.judgment, .preserve)
        XCTAssertNil(absent.issue)
        XCTAssertEqual(absent.bytes, 0)
        XCTAssertTrue(absent.reason.contains("경로가 없습니다"))
    }

    func testIndividualRemovalIsNeverAddedToBatchReadyGroup() {
        let app = StorageItem(json: ["kind": "application", "cleanupId": "app_uninstall:example.app", "path": "/Applications/Example.app"])!
        let result = StorageInvestigation.evidence(item: app, result: response(id: "app_uninstall:example.app"))
        XCTAssertEqual(result.judgment, .preserve)
    }

    func testInvestigationCannotOpenApprovalOrExecuteAndRetryPreservesOtherEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modore-investigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))
        let context = CleanupExecutionContext(execution: RuntimeExecutionContext(runtimeRoot: root,
            outputRoot: root, configurationURL: root.appendingPathComponent("config.json"), usesBundledRuntime: false,
            runtimeRootIdentity: identity, outputRootIdentity: identity, signedBundleURL: nil, sealedRuntimeFiles: nil),
            invocationArgument: "unused", pinnedFiles: [:], environment: [:])
        let probe = InvestigationProbe()
        let result = response()
        let client = CleanupExecutionClient(prepare: { _ in context }, preview: { _, _, _ in
            await probe.preview(); return result
        }, execute: { _, _, _ in await probe.execute(); return nil })
        let model = ScanModel(automaticallyScansStaleResults: false, projectRoot: root,
            scanRunner: { _, _ in .scanFailed }, cleanupExecution: client)
        for task in model.cancelTrackedApplicationTasks() { await task.value }
        let previous = item("uv_cache", path: "/example/other")
        model.storageInvestigations[SpaceGoalSelection.key(previous)] = .evidence(item: previous, result: response(id: "uv_cache"))
        model.investigateStorage([item()])
        await model.cleanupTask?.value
        XCTAssertNil(model.cleanupRecoveryPlan)
        XCTAssertNil(model.cleanupPreview)
        XCTAssertFalse(model.cleanupInFlight)
        XCTAssertEqual(model.storageInvestigations.count, 2)
        model.investigateStorage([item()])
        await model.cleanupTask?.value
        XCTAssertEqual(model.storageInvestigations.count, 2)
        let counts = await probe.counts()
        XCTAssertEqual(counts.0, 2)
        XCTAssertEqual(counts.1, 0)
        XCTAssertTrue(model.recoveryHistory.isEmpty)
    }

    func testNoGoalResultAndJournalDoNotClaimGoalFailureOrSuccess() throws {
        let preview = try XCTUnwrap(CleanupPreview(protocolText: response().output))
        let plan = CleanupRecoveryPlan(baselineFreeBytes: 100, requestedGainBytes: 100,
            entries: [CleanupPlanEntry(preview: preview, tier: .safe, request: nil)], stopAtGoal: false)
        XCTAssertTrue(plan.canExecute)
        var journal = RecoveryHistory(plan: plan)
        journal.phase = .finished
        journal.finalFreeBytes = 300
        XCTAssertFalse(journal.goalMet)
        let decoded = try JSONDecoder().decode(RecoveryHistory.self, from: JSONEncoder().encode(journal))
        XCTAssertEqual(decoded.stopAtGoal, false)
        let result = CleanupRecoveryResult(baselineFreeBytes: 100, finalFreeBytes: 300, desiredFreeBytes: 200,
            plannedCount: 0, items: [], stoppedAfterFailure: false, rescanScheduled: false, stopAtGoal: false)
        XCTAssertFalse(result.goalMet)
        XCTAssertEqual(result.actualChangeBytes, 200)
    }
}
