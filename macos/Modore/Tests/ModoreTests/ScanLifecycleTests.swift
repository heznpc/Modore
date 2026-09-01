import Foundation
import XCTest
@testable import Modore

private actor ScanLifecycleGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var runCount = 0

    func wait() async {
        runCount += 1
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CleanupLifecycleProbe {
    private(set) var previewRequests: [CleanupExecutionRequest?] = []
    private(set) var executionRequests: [CleanupExecutionRequest?] = []

    func recordPreview(_ request: CleanupExecutionRequest?) {
        previewRequests.append(request)
    }

    func recordExecution(_ request: CleanupExecutionRequest?) {
        executionRequests.append(request)
    }

    func requests() -> (
        preview: [CleanupExecutionRequest?],
        execution: [CleanupExecutionRequest?]
    ) {
        (previewRequests, executionRequests)
    }
}

private actor ScanPostProcessingGate {
    private let result: LoadedScanResult
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    init(result: LoadedScanResult) {
        self.result = result
    }

    func arm() {
        armed = true
        entered = false
    }

    func load() async -> LoadedScanResult {
        guard armed else { return result }
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return result
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ScanOutputLifecycleProbe {
    private var receiver: (@Sendable (String) -> Void)?

    func record(_ receiver: @escaping @Sendable (String) -> Void) {
        self.receiver = receiver
    }

    func emit(_ line: String) {
        receiver?(line)
    }
}

@MainActor
final class ScanLifecycleTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("modore-scan-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func settleStartup(_ model: ScanModel) async {
        for task in model.cancelTrackedApplicationTasks() {
            await task.value
        }
    }

    private func makeCleanupContext(in root: URL) throws -> CleanupExecutionContext {
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let configuration = root.appendingPathComponent("config.json")
        try Data("{}\n".utf8).write(to: configuration)
        return CleanupExecutionContext(
            execution: RuntimeExecutionContext(
                runtimeRoot: runtime,
                outputRoot: output,
                configurationURL: configuration,
                usesBundledRuntime: false,
                runtimeRootIdentity: try XCTUnwrap(FilesystemIdentity.directory(at: runtime)),
                outputRootIdentity: try XCTUnwrap(FilesystemIdentity.directory(at: output)),
                signedBundleURL: nil,
                sealedRuntimeFiles: nil
            ),
            invocationArgument: "@pch-pinned:cleanup",
            pinnedFiles: ["cleanup": Data("sealed cleanup".utf8)],
            environment: [:]
        )
    }

    private func processResult(
        _ output: String,
        status: Int32 = 0,
        endState: ProcessEndState = .exited
    ) -> CapturedProcessResult {
        CapturedProcessResult(
            status: status,
            output: output,
            endState: endState,
            outputTruncated: false
        )
    }

    private func readyCleanupPreview(
        recipeID: String = "project_residue",
        label: String = "Swift build"
    ) throws -> CleanupPreview {
        let expires = Int(Date().addingTimeInterval(600).timeIntervalSince1970)
        return try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tready
        recipeId\t\(recipeID)
        label\t\(label)
        estimatedKB\t256
        approvalToken\t\(String(repeating: "a", count: 64))
        approvalExpiresEpoch\t\(expires)
        """))
    }

    private func cleanupExecutionResult(
        status: String,
        recipeID: String = "project_residue",
        label: String = "Swift build",
        blockedReason: String = "",
        stagedRemainder: String = ""
    ) -> CapturedProcessResult {
        let recoveryFields = [
            blockedReason.isEmpty ? nil : "blockedReason\t\(blockedReason)",
            stagedRemainder.isEmpty ? nil : "stagedRemainder\t\(stagedRemainder)",
        ].compactMap { $0 }.joined(separator: "\n")
        return processResult(
            """
            version\t1
            operation\texecute
            status\t\(status)
            actionMode\tremove
            recipeId\t\(recipeID)
            label\t\(label)
            reclaimedKB\t128
            physicalDeltaKB\t128
            \(recoveryFields)
            """,
            status: status == "complete" ? 0 : 1
        )
    }

    private func recoveryPlan(for preview: CleanupPreview) -> CleanupRecoveryPlan {
        CleanupRecoveryPlan(
            baselineFreeGB: 1,
            desiredFreeGB: 100,
            entries: [CleanupPlanEntry(preview: preview, tier: .rebuild, request: nil)]
        )
    }

    private func freeSpaceObservation() -> Observation<LiveFreeSpace> {
        Observation(
            value: LiveFreeSpace(
                freeBytes: 1_073_741_824,
                totalBytes: 107_374_182_400
            ),
            observedAt: Date(),
            source: .systemVolume
        )
    }

    private func projectStorageItem(in root: URL) throws -> StorageItem {
        try XCTUnwrap(StorageItem(json: [
            "risk": "warning",
            "kind": "project_residue",
            "label": "Swift build",
            "sizeGB": 1,
            "path": root.appendingPathComponent("Project/.build").path,
            "action": "정리",
            "measureStatus": "ok",
            "cleanupId": "project_residue",
        ]))
    }

    private func publishCanonicalScan(in root: URL) throws {
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))
        let staged = try ScanPublication.prepare(
            in: root,
            expectedParentIdentity: identity
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": "1.0",
            "scannedAt": "2026-09-01 09:00:00",
            "sections": [:],
        ])
        try payload.write(to: staged.scanResultURL, options: .atomic)
        try payload.write(to: staged.rawFactsURL, options: .atomic)
        XCTAssertTrue(ScanPublication.publish(
            staged,
            in: root,
            expectedParentIdentity: identity
        ))
    }

    @discardableResult
    private func waitUntil(
        _ message: String,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(message)
        return false
    }

    @discardableResult
    private func waitForEntry(
        _ gate: ScanLifecycleGate,
        _ message: String
    ) async -> Bool {
        for _ in 0..<400 {
            if await gate.entered { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(message)
        return false
    }

    func testRunScanPublishesSuccessAndClearsOwnedTask() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = ScanRunResult(
            scan: .succeeded,
            normalReport: .succeeded,
            shareReport: .failed
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { receivedRoot, onOutput in
                XCTAssertEqual(receivedRoot, root)
                onOutput("가짜 수집 단계")
                return expected
            }
        )
        await settleStartup(model)

        model.runScan()

        await waitUntil("successful scan did not finish") {
            model.state == .finished && model.scanTask == nil
        }
        await waitUntil("scan output did not reach the model log") {
            model.logText.contains("가짜 수집 단계")
        }
        XCTAssertEqual(model.reportState.normal, .generated)
        XCTAssertEqual(model.reportState.share, .failed)
        XCTAssertEqual(model.reportRevision, 1)
    }

    func testRunScanPublishesFailureAndClearsOwnedTask() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in .scanFailed }
        )
        await settleStartup(model)

        model.runScan()

        await waitUntil("failed scan did not leave the running state") {
            model.state == .failed && model.scanTask == nil
        }
        XCTAssertNotNil(model.deepScanFailure)
    }

    func testCancelScanWaitsForRunnerCleanupThenReturnsToIdle() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScanLifecycleGate()
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in
                await gate.wait()
                return .scanFailed
            }
        )
        await settleStartup(model)

        model.runScan()
        for _ in 0..<400 {
            if await gate.entered { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let didEnter = await gate.entered
        XCTAssertTrue(didEnter)
        XCTAssertEqual(model.state, .running)

        model.cancelScan()
        XCTAssertTrue(model.scanTask?.isCancelled == true)
        await gate.release()

        await waitUntil("cancelled scan did not release its owned task") {
            model.state == .idle && model.scanTask == nil
        }
        XCTAssertTrue(model.logText.contains("검사를 취소했습니다."))
    }

    func testSecondRunIsRejectedWhileFirstRunnerOwnsLifecycle() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScanLifecycleGate()
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in
                await gate.wait()
                return .scanFailed
            }
        )
        await settleStartup(model)

        model.runScan()
        for _ in 0..<400 {
            if await gate.entered { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let didEnter = await gate.entered
        XCTAssertTrue(didEnter)

        model.runScan()
        let runCount = await gate.runCount
        XCTAssertEqual(runCount, 1)
        await gate.release()
        await waitUntil("first scan did not finish after its gate was released") {
            model.state == .failed && model.scanTask == nil
        }
    }

    func testCancelDuringPostProcessingCannotPublishLateSuccess() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = ScanResultLoader.load(projectRoot: root)
        let postProcessing = ScanPostProcessingGate(result: loaded)
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in
                ScanRunResult(
                    scan: .succeeded,
                    normalReport: .succeeded,
                    shareReport: .succeeded
                )
            },
            existingResultsLoader: { _ in await postProcessing.load() },
            storageWatchEvidenceLoader: { nil }
        )
        await settleStartup(model)
        await postProcessing.arm()

        model.runScan()
        for _ in 0..<400 {
            if await postProcessing.entered { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let postProcessingEntered = await postProcessing.entered
        XCTAssertTrue(postProcessingEntered)

        model.cancelScan()
        await postProcessing.release()

        await waitUntil("post-processing cancellation published a late success") {
            model.state == .idle && model.scanTask == nil && !model.resultLoading
        }
        XCTAssertEqual(model.reportRevision, 0)
        XCTAssertFalse(model.logText.contains("완료: 정밀 검사"))
    }

    func testTerminationDuringPostProcessingDrainsWithoutPublishing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = ScanResultLoader.load(projectRoot: root)
        let postProcessing = ScanPostProcessingGate(result: loaded)
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in
                ScanRunResult(
                    scan: .succeeded,
                    normalReport: .succeeded,
                    shareReport: .succeeded
                )
            },
            existingResultsLoader: { _ in await postProcessing.load() },
            storageWatchEvidenceLoader: { nil }
        )
        await settleStartup(model)
        await postProcessing.arm()

        model.runScan()
        for _ in 0..<400 {
            if await postProcessing.entered { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let postProcessingEntered = await postProcessing.entered
        XCTAssertTrue(postProcessingEntered)
        let terminationFinished = expectation(description: "termination task drain")
        XCTAssertTrue(model.cancelApplicationTasksForTermination {
            terminationFinished.fulfill()
        })

        await postProcessing.release()
        await fulfillment(of: [terminationFinished], timeout: 2)

        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.reportRevision, 0)
        XCTAssertFalse(model.logText.contains("완료: 정밀 검사"))
        XCTAssertNil(model.applicationTerminationWaitTask)
        XCTAssertNil(model.applicationTerminationDeadlineTask)
    }

    func testCancelledScanRejectsOutputFromItsRetainedCallback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = ScanLifecycleGate()
        let output = ScanOutputLifecycleProbe()
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, receiver in
                await output.record(receiver)
                await lifecycle.wait()
                return .scanFailed
            }
        )
        await settleStartup(model)

        model.runScan()
        for _ in 0..<400 {
            if await lifecycle.entered { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let runnerEntered = await lifecycle.entered
        XCTAssertTrue(runnerEntered)

        model.cancelScan()
        await output.emit("cancelled scan stale output")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.logText.contains("cancelled scan stale output"))

        await lifecycle.release()
        await waitUntil("cancelled scan left an owned output task behind") {
            model.state == .idle && model.scanTask == nil
        }
        await output.emit("finished scan stale output")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.logText.contains("finished scan stale output"))
    }

    func testOutputBufferBoundsAndCoalescesNewestLines() {
        let output = BoundedScanOutputBuffer(
            maximumBufferedBytes: 128,
            maximumBufferedLines: 3
        )

        for line in ["one", "two", "three", "four", "five"] {
            output.send(line)
        }

        let batch = output.takeBatch()
        XCTAssertEqual(batch?.lines, ["three", "four", "five"])
        XCTAssertEqual(batch?.omittedLineCount, 2)
        XCTAssertTrue(batch?.text.contains("버퍼 상한으로 생략") == true)
        XCTAssertNil(output.takeBatch())
        output.finish()
    }

    func testCancelledSinglePreviewCannotPublishReturnedRequest() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeCleanupContext(in: root)
        let previewGate = ScanLifecycleGate()
        let ready = try readyCleanupPreview()
        let previewResult = processResult("""
        version\t1
        operation\tpreview
        status\tready
        recipeId\t\(ready.recipeID)
        label\t\(ready.label)
        approvalToken\t\(ready.approvalToken)
        """)
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in context },
            preview: { _, _, _ in
                await previewGate.wait()
                return previewResult
            },
            execute: { _, _, _ in nil }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            cleanupExecution: cleanupClient
        )
        await settleStartup(model)
        let item = try projectStorageItem(in: root)

        model.prepareCleanup(item)
        await waitForEntry(previewGate, "single cleanup preview did not enter")
        model.cancelCleanupPreviewRequest()
        await previewGate.release()
        await waitUntil("cancelled single preview did not drain") {
            model.cleanupTask == nil && !model.cleanupInFlight
        }

        XCTAssertNil(model.cleanupPreview)
        XCTAssertNil(model.cleanupRequest)
        XCTAssertFalse(model.logText.contains("미리보기: 실행 준비됨"))
    }

    func testCancelledBatchPreviewCannotPublishReturnedPlan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeCleanupContext(in: root)
        let previewGate = ScanLifecycleGate()
        let ready = try readyCleanupPreview()
        let previewResult = processResult("""
        version\t1
        operation\tpreview
        status\tready
        recipeId\t\(ready.recipeID)
        label\t\(ready.label)
        approvalToken\t\(ready.approvalToken)
        approvalExpiresEpoch\t\(Int(Date().addingTimeInterval(600).timeIntervalSince1970))
        """)
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in context },
            preview: { _, _, _ in
                await previewGate.wait()
                return previewResult
            },
            execute: { _, _, _ in nil }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            cleanupExecution: cleanupClient
        )
        await settleStartup(model)

        model.prepareRecoveryPlan(
            [try projectStorageItem(in: root)],
            desiredFreeGB: 100
        )
        await waitForEntry(previewGate, "batch cleanup preview did not enter")
        model.cancelCleanupPreviewRequest()
        await previewGate.release()
        await waitUntil("cancelled batch preview did not drain") {
            model.cleanupTask == nil && !model.cleanupInFlight
        }

        XCTAssertNil(model.cleanupRecoveryPlan)
        XCTAssertFalse(model.logText.contains("공간 확보 계획 준비 완료"))
    }

    func testSinglePrepareKeepsSafetyGateClosedAndSkipsExecutionAfterTermination() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeCleanupContext(in: root)
        let prepareGate = ScanLifecycleGate()
        let cleanupProbe = CleanupLifecycleProbe()
        let preview = try readyCleanupPreview()
        let unusedPreviewResult = processResult("")
        let completeResult = cleanupExecutionResult(status: "complete")
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in
                await prepareGate.wait()
                return context
            },
            preview: { _, _, _ in unusedPreviewResult },
            execute: { _, request, _ in
                await cleanupProbe.recordExecution(request)
                return completeResult
            }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            cleanupExecution: cleanupClient
        )
        await settleStartup(model)
        model.cleanupPreview = preview

        model.executeCleanup(preview)
        await waitForEntry(prepareGate, "single cleanup prepare did not enter")
        XCTAssertFalse(model.cleanupIsExecuting)
        XCTAssertEqual(model.terminationSafetyState, .safe)

        let terminationFinished = expectation(description: "single prepare termination drain")
        XCTAssertTrue(model.cancelApplicationTasksForTermination {
            terminationFinished.fulfill()
        })
        XCTAssertFalse(model.deferApplicationTerminationUntilSafe {})
        await prepareGate.release()
        await fulfillment(of: [terminationFinished], timeout: 2)

        let requests = await cleanupProbe.requests()
        XCTAssertTrue(requests.execution.isEmpty)
        XCTAssertEqual(model.terminationSafetyState, .safe)
        XCTAssertNil(model.cleanupTask)
    }

    func testBatchPrepareKeepsSafetyGateClosedAndSkipsExecutionAfterTermination() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeCleanupContext(in: root)
        let prepareGate = ScanLifecycleGate()
        let cleanupProbe = CleanupLifecycleProbe()
        let preview = try readyCleanupPreview()
        let plan = recoveryPlan(for: preview)
        let observation = freeSpaceObservation()
        let unusedPreviewResult = processResult("")
        let completeResult = cleanupExecutionResult(status: "complete")
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in
                await prepareGate.wait()
                return context
            },
            preview: { _, _, _ in unusedPreviewResult },
            execute: { _, request, _ in
                await cleanupProbe.recordExecution(request)
                return completeResult
            }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            cleanupExecution: cleanupClient
        )
        await settleStartup(model)
        model.cleanupRecoveryPlan = plan

        model.executeRecoveryPlan(plan, observeFreeSpace: { observation })
        await waitForEntry(prepareGate, "batch cleanup prepare did not enter")
        XCTAssertFalse(model.cleanupIsExecuting)
        XCTAssertEqual(model.terminationSafetyState, .safe)

        let terminationFinished = expectation(description: "batch prepare termination drain")
        XCTAssertTrue(model.cancelApplicationTasksForTermination {
            terminationFinished.fulfill()
        })
        XCTAssertFalse(model.deferApplicationTerminationUntilSafe {})
        await prepareGate.release()
        await fulfillment(of: [terminationFinished], timeout: 2)

        let requests = await cleanupProbe.requests()
        XCTAssertTrue(requests.execution.isEmpty)
        XCTAssertEqual(model.terminationSafetyState, .safe)
        XCTAssertNil(model.cleanupTask)
    }

    func testSinglePartialCleanupClosesSafetyGateAndStartsCanonicalRescan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try publishCanonicalScan(in: root)
        let context = try makeCleanupContext(in: root)
        let executeGate = ScanLifecycleGate()
        let scanGate = ScanLifecycleGate()
        let preview = try readyCleanupPreview()
        let unusedPreviewResult = processResult("")
        let recoveryPath = root.appendingPathComponent("cleanup-staging/recover-me").path
        let partialResult = cleanupExecutionResult(
            status: "partial",
            blockedReason: "일부 항목을 격리한 뒤 중단했습니다.",
            stagedRemainder: recoveryPath
        )
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in context },
            preview: { _, _, _ in unusedPreviewResult },
            execute: { _, _, _ in
                await executeGate.wait()
                return partialResult
            }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in
                await scanGate.wait()
                return .scanFailed
            },
            cleanupExecution: cleanupClient
        )
        await settleStartup(model)
        model.cleanupPreview = preview

        model.executeCleanup(preview)
        await waitForEntry(executeGate, "single cleanup execute did not enter")
        XCTAssertTrue(model.cleanupIsExecuting)
        XCTAssertEqual(model.terminationSafetyState, .destructiveCleanupInProgress)
        XCTAssertTrue(model.cleanupMutationPending)
        XCTAssertTrue(ScanPublication.cleanupMutationIsPending(in: root))
        await executeGate.release()
        await waitForEntry(scanGate, "single partial cleanup did not start a rescan")

        XCTAssertFalse(model.cleanupIsExecuting)
        XCTAssertEqual(model.terminationSafetyState, .safe)
        XCTAssertEqual(model.state, .running)
        XCTAssertTrue(model.cleanupMutationPending)
        XCTAssertTrue(ScanPublication.cleanupMutationIsPending(in: root))
        XCTAssertEqual(model.errorMessage, "일부 항목을 격리한 뒤 중단했습니다.\n격리 보존 경로: \(recoveryPath)")
        XCTAssertTrue(model.logText.contains("격리 보존 경로: \(recoveryPath)"))
        XCTAssertTrue(model.logText.contains("정리 후 현재 상태를 다시 검사합니다."))
        model.cancelScan()
        await scanGate.release()
        await waitUntil("single partial cleanup rescan did not drain") {
            model.scanTask == nil && model.state == .idle
        }

        let restarted = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root
        )
        XCTAssertTrue(restarted.cleanupMutationPending)
        XCTAssertTrue(restarted.deepScanSnapshotNeedsRefresh())
        await settleStartup(restarted)
    }

    func testTerminationReplyWaitsUntilCleanupMutationMarkerIsDurable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try publishCanonicalScan(in: root)
        let context = try makeCleanupContext(in: root)
        let executeGate = ScanLifecycleGate()
        let preview = try readyCleanupPreview()
        let partialResult = cleanupExecutionResult(status: "partial")
        let unusedPreviewResult = processResult("")
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in context },
            preview: { _, _, _ in unusedPreviewResult },
            execute: { _, _, _ in
                await executeGate.wait()
                return partialResult
            }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            cleanupExecution: cleanupClient
        )
        await settleStartup(model)
        model.cleanupPreview = preview

        model.executeCleanup(preview)
        await waitForEntry(executeGate, "cleanup execute did not enter")
        XCTAssertEqual(model.terminationSafetyState, .destructiveCleanupInProgress)
        XCTAssertTrue(ScanPublication.cleanupMutationIsPending(in: root))

        let reply = expectation(description: "termination safety reply")
        var markerWasDurableAtReply = false
        _ = model.cancelApplicationTasksForTermination {}
        XCTAssertTrue(model.deferApplicationTerminationUntilSafe {
            markerWasDurableAtReply = ScanPublication.cleanupMutationIsPending(in: root)
            reply.fulfill()
        })
        await executeGate.release()
        await fulfillment(of: [reply], timeout: 2)

        XCTAssertTrue(markerWasDurableAtReply)
        XCTAssertEqual(model.terminationSafetyState, .safe)
        await waitUntil("cleanup task did not drain after termination reply") {
            model.cleanupTask == nil
        }
    }

    func testSingleCleanupDoesNotExecuteWhenMutationIntentCannotBePersisted() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeCleanupContext(in: root)
        let cleanupProbe = CleanupLifecycleProbe()
        let scanGate = ScanLifecycleGate()
        let preview = try readyCleanupPreview()
        let unusedPreviewResult = processResult("")
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in context },
            preview: { _, _, _ in unusedPreviewResult },
            execute: { _, request, _ in
                await cleanupProbe.recordExecution(request)
                return nil
            }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in
                await scanGate.wait()
                return .scanFailed
            },
            cleanupExecution: cleanupClient,
            cleanupMutationRecorder: { _ in false }
        )
        await settleStartup(model)
        model.cleanupPreview = preview

        model.executeCleanup(preview)
        await waitUntil("blocked single cleanup did not finish") {
            model.cleanupTask == nil && !model.cleanupInFlight
        }

        let requests = await cleanupProbe.requests()
        XCTAssertTrue(requests.execution.isEmpty)
        let runCount = await scanGate.runCount
        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.terminationSafetyState, .safe)
        XCTAssertFalse(model.cleanupMutationPending)
        XCTAssertTrue(model.errorMessage?.contains("디스크에 기록하지 못해 실행하지 않았습니다") == true)
    }

    func testBatchPartialCleanupClosesSafetyGateAndStartsCanonicalRescan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try publishCanonicalScan(in: root)
        let context = try makeCleanupContext(in: root)
        let executeGate = ScanLifecycleGate()
        let scanGate = ScanLifecycleGate()
        let preview = try readyCleanupPreview()
        let plan = recoveryPlan(for: preview)
        let observation = freeSpaceObservation()
        let unusedPreviewResult = processResult("")
        let partialResult = cleanupExecutionResult(status: "partial")
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in context },
            preview: { _, _, _ in unusedPreviewResult },
            execute: { _, _, _ in
                await executeGate.wait()
                return partialResult
            }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in
                await scanGate.wait()
                return .scanFailed
            },
            cleanupExecution: cleanupClient
        )
        await settleStartup(model)
        model.cleanupRecoveryPlan = plan

        model.executeRecoveryPlan(plan, observeFreeSpace: { observation })
        await waitForEntry(executeGate, "batch cleanup execute did not enter")
        XCTAssertTrue(model.cleanupIsExecuting)
        XCTAssertEqual(model.terminationSafetyState, .destructiveCleanupInProgress)
        XCTAssertTrue(model.cleanupMutationPending)
        XCTAssertTrue(ScanPublication.cleanupMutationIsPending(in: root))
        await executeGate.release()
        await waitForEntry(scanGate, "batch partial cleanup did not start a rescan")

        XCTAssertTrue(model.cleanupRecoveryResult?.rescanScheduled == true)
        XCTAssertFalse(model.cleanupIsExecuting)
        XCTAssertEqual(model.terminationSafetyState, .safe)
        model.cancelScan()
        await scanGate.release()
        await waitUntil("batch partial cleanup rescan did not drain") {
            model.scanTask == nil && model.state == .idle
        }
    }

    func testBatchCleanupDoesNotExecuteWhenMutationIntentCannotBePersisted() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeCleanupContext(in: root)
        let cleanupProbe = CleanupLifecycleProbe()
        let scanGate = ScanLifecycleGate()
        let preview = try readyCleanupPreview()
        let plan = recoveryPlan(for: preview)
        let observation = freeSpaceObservation()
        let unusedPreviewResult = processResult("")
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in context },
            preview: { _, _, _ in unusedPreviewResult },
            execute: { _, request, _ in
                await cleanupProbe.recordExecution(request)
                return nil
            }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in
                await scanGate.wait()
                return .scanFailed
            },
            cleanupExecution: cleanupClient,
            cleanupMutationRecorder: { _ in false }
        )
        await settleStartup(model)
        model.cleanupRecoveryPlan = plan

        model.executeRecoveryPlan(plan, observeFreeSpace: { observation })
        await waitUntil("blocked batch cleanup did not finish") {
            model.cleanupTask == nil && !model.cleanupInFlight
        }

        let requests = await cleanupProbe.requests()
        XCTAssertTrue(requests.execution.isEmpty)
        let runCount = await scanGate.runCount
        XCTAssertEqual(runCount, 0)
        XCTAssertFalse(model.cleanupRecoveryResult?.rescanScheduled ?? true)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.terminationSafetyState, .safe)
        XCTAssertFalse(model.cleanupMutationPending)
        XCTAssertTrue(model.errorMessage?.contains("디스크에 기록하지 못해 실행하지 않았습니다") == true)
    }

    func testProjectCleanupPreservesRequestAndStartsCancellableRescanOutsideSafetyGate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeCleanupContext(in: root)
        let cleanupProbe = CleanupLifecycleProbe()
        let scanGate = ScanLifecycleGate()
        let token = String(repeating: "a", count: 64)
        let previewResult = processResult("""
        version\t1
        operation\tpreview
        status\tready
        recipeId\tproject_residue
        label\tSwift build
        approvalToken\t\(token)
        """)
        let executionResult = processResult("""
        version\t1
        operation\texecute
        status\tcomplete
        actionMode\tremove
        recipeId\tproject_residue
        label\tSwift build
        reclaimedKB\t128
        physicalDeltaKB\t128
        """)
        let cleanupClient = CleanupExecutionClient(
            prepare: { _ in context },
            preview: { _, request, _ in
                await cleanupProbe.recordPreview(request)
                return previewResult
            },
            execute: { _, request, _ in
                await cleanupProbe.recordExecution(request)
                return executionResult
            }
        )
        let model = ScanModel(
            automaticallyScansStaleResults: false,
            projectRoot: root,
            scanRunner: { _, _ in
                await scanGate.wait()
                return .scanFailed
            },
            cleanupExecution: cleanupClient
        )
        await settleStartup(model)
        let item = try XCTUnwrap(StorageItem(json: [
            "risk": "warning",
            "kind": "project_residue",
            "label": "Swift build",
            "sizeGB": 1,
            "path": root.appendingPathComponent("Project/.build").path,
            "action": "정리",
            "measureStatus": "ok",
            "cleanupId": "project_residue",
        ]))
        let expectedRequest = try XCTUnwrap(CleanupExecutionRequest(item: item))

        model.prepareCleanup(item)
        await waitUntil("project cleanup preview did not finish") {
            model.cleanupPreview?.canExecute == true && model.cleanupTask == nil
        }
        let preview = try XCTUnwrap(model.cleanupPreview)
        var requests = await cleanupProbe.requests()
        XCTAssertEqual(requests.preview, [expectedRequest])

        model.executeCleanup(preview)
        for _ in 0..<400 {
            if await scanGate.entered { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let postCleanupScanEntered = await scanGate.entered
        XCTAssertTrue(postCleanupScanEntered)
        requests = await cleanupProbe.requests()
        XCTAssertEqual(requests.execution, [expectedRequest])
        XCTAssertNil(model.cleanupTask)
        XCTAssertFalse(model.cleanupInFlight)
        XCTAssertFalse(model.cleanupIsExecuting)
        XCTAssertEqual(model.terminationSafetyState, .safe)
        XCTAssertEqual(model.state, .running)
        XCTAssertNotNil(model.scanTask)

        model.cancelScan()
        XCTAssertTrue(model.scanTask?.isCancelled == true)
        await scanGate.release()
        await waitUntil("post-cleanup scan did not release after cancellation") {
            model.state == .idle && model.scanTask == nil
        }
    }
}
