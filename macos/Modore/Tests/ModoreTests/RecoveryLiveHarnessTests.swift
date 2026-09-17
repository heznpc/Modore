import Darwin
import Foundation
import XCTest
@testable import Modore

/// Runs the real shell, pinned-FD transport, plan controller and durable journal.
/// Only the freshly created test home's generated directory is disposable.
@MainActor
final class RecoveryLiveHarnessTests: XCTestCase {
    func testRealPreviewExecutionReceiptAndRestartOnIsolatedGeneratedData() async throws {
        let manager = FileManager.default
        // Foundation deliberately abbreviates /private/var to /var; the shell
        // safety contract uses physical POSIX paths and must see the same name.
        let canonicalTemporary = try XCTUnwrap(realpath(manager.temporaryDirectory.path, nil))
        defer { free(canonicalTemporary) }
        let root = URL(fileURLWithPath: String(cString: canonicalTemporary))
            .appendingPathComponent("modore-live-recovery-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = home.appendingPathComponent("Projects/fixture")
        let target = project.appendingPathComponent("node_modules")
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = project.appendingPathComponent("package.json")
        try Data("{}\n".utf8).write(to: marker)
        try Data(repeating: 0x61, count: 128 * 1024).write(to: target.appendingPathComponent("generated.bin"))
        let configuration = root.appendingPathComponent("config.json")
        try Data("{}\n".utf8).write(to: configuration)

        let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let scripts = repository.appendingPathComponent("scripts")
        // Test mode is embedded in this test-only sealed input, not an override
        // accepted by the production process runner or installed app.
        let prelude = "export PCH_TEST_MODE=1\nexport PCH_HOME_OVERRIDE='\(home.path)'\n"
        let shell = prelude + (try String(contentsOf: scripts.appendingPathComponent("cleanup.sh")))
        let context = CleanupExecutionContext(
            execution: RuntimeExecutionContext(
                runtimeRoot: root, outputRoot: root, configurationURL: configuration,
                usesBundledRuntime: false,
                runtimeRootIdentity: try XCTUnwrap(FilesystemIdentity.directory(at: root)),
                outputRootIdentity: try XCTUnwrap(FilesystemIdentity.directory(at: root)),
                signedBundleURL: nil, sealedRuntimeFiles: nil
            ),
            invocationArgument: "@pch-pinned:cleanup",
            pinnedFiles: [
                "cleanup": Data(shell.utf8),
                "support": try Data(contentsOf: scripts.appendingPathComponent("modules/support_dir.sh")),
                "approval": try Data(contentsOf: scripts.appendingPathComponent("modules/approval_token.sh")),
            ],
            environment: [
                "PCH_PINNED_SUPPORT_DIR_MODULE": "@pch-pinned:support",
                "PCH_PINNED_APPROVAL_TOKEN_MODULE": "@pch-pinned:approval",
            ]
        )
        let client = CleanupExecutionClient(prepare: { _ in context },
                                            preview: CleanupExecutionClient.live.preview,
                                            execute: CleanupExecutionClient.live.execute)
        let model = ScanModel(automaticallyScansStaleResults: false, projectRoot: root,
                              scanRunner: { _, _ in .scanFailed }, cleanupExecution: client)
        for task in model.cancelTrackedApplicationTasks() { await task.value }
        let item = try XCTUnwrap(StorageItem(json: [
            "risk": "warning", "kind": "project_residue", "label": "isolated generated data",
            "sizeGB": 0.01, "path": target.path, "action": "정리",
            "measureStatus": "ok", "cleanupId": "project_residue",
        ]))
        model.prepareRecoveryPlan([item], requestedGainBytes: 100 * StorageBytes.perGiB)
        await model.cleanupTask?.value
        let plan = try XCTUnwrap(model.cleanupRecoveryPlan, model.errorMessage ?? model.logText)
        _ = try XCTUnwrap(plan.readyEntries.first, plan.entries.map { $0.preview.blockedReason }.joined(separator: "; "))
        let reviewed = try XCTUnwrap(RecoveryHistoryStore.load(in: root).first)
        XCTAssertEqual(reviewed.phase, .reviewed)
        XCTAssertNil(reviewed.approvedAt)
        XCTAssertTrue(manager.fileExists(atPath: target.path))

        model.executeRecoveryPlan(plan)
        await model.cleanupTask?.value
        for task in model.cancelTrackedApplicationTasks() { await task.value }
        XCTAssertEqual(model.cleanupRecoveryResult?.succeededCount, 1, model.errorMessage ?? model.logText)
        XCTAssertNil(model.scanTask)
        XCTAssertFalse(model.cleanupRecoveryResult?.rescanScheduled ?? true)
        XCTAssertFalse(manager.fileExists(atPath: target.path))
        XCTAssertTrue(manager.fileExists(atPath: marker.path))
        let saved = try XCTUnwrap(RecoveryHistoryStore.load(in: root).first)
        XCTAssertEqual(saved.id, plan.id)
        XCTAssertEqual(saved.phase, .finished)
        XCTAssertNotNil(saved.approvedAt)
        XCTAssertNotNil(saved.finalFreeBytes)
        let result = try XCTUnwrap(saved.items.first)
        XCTAssertEqual(result.status, "complete")
        XCTAssertTrue(result.receipt.hasPrefix(home.path + "/"))
        XCTAssertTrue(manager.fileExists(atPath: result.receipt))
        let journal = try String(contentsOf: RecoveryHistoryStore.url(in: root))
        XCTAssertFalse(journal.contains(plan.readyEntries[0].preview.approvalToken))

        let restarted = ScanModel(automaticallyScansStaleResults: false, projectRoot: root,
                                  scanRunner: { _, _ in .scanFailed }, cleanupExecution: client)
        for task in restarted.cancelTrackedApplicationTasks() { await task.value }
        XCTAssertEqual(restarted.recoveryHistory.first, saved)
        XCTAssertNil(restarted.cleanupRecoveryPlan)
        XCTAssertFalse(restarted.cleanupInFlight)
    }
}
