import Foundation
import XCTest
@testable import Modore

private actor ReviewWorkflowProbe {
    var previews = 0
    var executions = 0
    func preview() { previews += 1 }
    func execute() { executions += 1 }
    func counts() -> (Int, Int) { (previews, executions) }
}

@MainActor
final class StorageReviewWorkflowTests: XCTestCase {
    private func loaded() -> LoadedScanResult {
        LoadedScanResult(content: ScanContent(root: ["sections": ["storage": [
            "volume": ["mount": "/", "freeGB": 30, "totalGB": 100, "usedGB": 70, "usePercent": 70, "risk": "safe"],
            "cleanupCandidates": [["kind": "cache", "cleanupId": "pip_cache", "label": "Cache",
                                   "path": "/example/cache", "sizeGB": 1, "measureStatus": "ok"]]
        ]]]), deepScanAt: Date(), storageHistory: [], displayedStorageEntry: nil,
           storageChange: nil, freeSpaceSamples: [], diagnostic: nil)
    }

    private func run(success: Bool, cancel: Bool = false) async throws -> (Int, Int) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modore-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))
        let context = CleanupExecutionContext(execution: RuntimeExecutionContext(runtimeRoot: root,
            outputRoot: root, configurationURL: root.appendingPathComponent("config.json"), usesBundledRuntime: false,
            runtimeRootIdentity: identity, outputRootIdentity: identity, signedBundleURL: nil, sealedRuntimeFiles: nil),
            invocationArgument: "unused", pinnedFiles: [:], environment: [:])
        let probe = ReviewWorkflowProbe()
        let client = CleanupExecutionClient(prepare: { _ in context }, preview: { _, _, _ in
            await probe.preview()
            return CapturedProcessResult(status: 1, output: "", endState: .exited, outputTruncated: false)
        }, execute: { _, _, _ in await probe.execute(); return nil })
        let snapshot = loaded()
        let model = ScanModel(automaticallyScansStaleResults: false, projectRoot: root,
            scanRunner: { _, _ in success
                ? ScanRunResult(scan: .succeeded, normalReport: .succeeded, shareReport: .succeeded)
                : .scanFailed },
            existingResultsLoader: { _ in snapshot }, storageWatchEvidenceLoader: { nil },
            cleanupExecution: client)
        for task in model.cancelTrackedApplicationTasks() { await task.value }
        model.prepareStorageReview(additionalCandidates: { [] })
        let operations = model.trackedApplicationTasks.values.map(\.task)
        if cancel { model.cancelScan() }
        for task in operations { await task.value }
        await model.scanTask?.value
        await model.cleanupTask?.value
        XCTAssertNil(model.cleanupPreview)
        XCTAssertNil(model.cleanupRecoveryPlan)
        XCTAssertTrue(model.recoveryHistory.isEmpty)
        return await probe.counts()
    }

    func testOneActionDiscoversAndInvestigatesWithoutSelectingApprovingOrExecuting() async throws {
        let counts = try await run(success: true)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 0)
    }

    func testFailedScanDoesNotInvestigateOldInventory() async throws {
        let counts = try await run(success: false)
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testCancelledScanDoesNotContinueIntoInvestigation() async throws {
        let counts = try await run(success: true, cancel: true)
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }
}
