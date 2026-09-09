import Foundation
import XCTest
@testable import Modore

@MainActor
final class CleanupPreviewBatchTests: XCTestCase {
    func testDeadlineRetainsReadyResultsAndCancelsSlowCandidates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modore-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CleanupExecutionContext(
            execution: RuntimeExecutionContext(
                runtimeRoot: root, outputRoot: root, configurationURL: root.appendingPathComponent("config.json"),
                usesBundledRuntime: false,
                runtimeRootIdentity: try XCTUnwrap(FilesystemIdentity.directory(at: root)),
                outputRootIdentity: try XCTUnwrap(FilesystemIdentity.directory(at: root)),
                signedBundleURL: nil, sealedRuntimeFiles: nil
            ), invocationArgument: "unused", pinnedFiles: [:], environment: [:]
        )
        let client = CleanupExecutionClient(prepare: { _ in context }, preview: { id, _, _ in
            if id == "slow" {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { return CapturedProcessResult(status: -1, output: "", endState: .cancelled, outputTruncated: false) }
            }
            return CapturedProcessResult(status: 0, output: id, endState: .exited, outputTruncated: false)
        }, execute: { _, _, _ in nil })
        let start = Date()
        let results = await CleanupPreviewBatch.run(
            [("slow", nil), ("ready", nil), ("also-ready", nil)],
            context: context, client: client, budget: 0.2, progress: { _, _ in }
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(results[1]?.output, "ready")
        XCTAssertEqual(results[2]?.output, "also-ready")
        XCTAssertNil(results[0])
        let empty = await CleanupPreviewBatch.run([], context: context, client: client, progress: { _, _ in })
        XCTAssertTrue(empty.isEmpty)
    }

    func testUnavailableCandidateCannotCarryAnApprovalOrTargets() {
        let preview = CleanupPreview.unavailable(recipeID: "npm_cache", label: "cache", reason: "timeout\ntarget\t/private/data")
        XCTAssertFalse(preview.canExecute)
        XCTAssertTrue(preview.targets.isEmpty)
        XCTAssertTrue(preview.approvalToken.isEmpty)
        XCTAssertEqual(preview.status, "unavailable")
    }
}
