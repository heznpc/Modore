import ModoreDomain
import XCTest
@testable import Modore

final class StorageRecoveryTests: XCTestCase {
    func testRequiredGainTargetsTwentyGBWithoutGoingNegative() {
        XCTAssertEqual(StorageRecoveryPolicy.requiredGainGB(currentFreeGB: 2.6), 17.4, accuracy: 0.000_001)
        XCTAssertEqual(StorageRecoveryPolicy.requiredGainGB(currentFreeGB: 20), 0)
        XCTAssertEqual(StorageRecoveryPolicy.requiredGainGB(currentFreeGB: 40), 0)
    }

    func testBatchTierKeepsIndividualConsequencesOutOfOneApprovalPlan() {
        XCTAssertEqual(CleanupRecipeCatalog.batchTier(recipeID: "npm_cache"), .safe)
        XCTAssertEqual(CleanupRecipeCatalog.batchTier(recipeID: "xcode_derived_data"), .rebuild)
        XCTAssertEqual(CleanupRecipeCatalog.batchTier(recipeID: "project_residue"), .rebuild)
        XCTAssertNil(CleanupRecipeCatalog.batchTier(recipeID: "ollama_models"))
        XCTAssertNil(CleanupRecipeCatalog.batchTier(recipeID: "innorix_ex"))
        XCTAssertNil(CleanupRecipeCatalog.batchTier(recipeID: "app_uninstall:example.app"))
    }

    func testGoalSelectionUsesSafeCachesBeforeALargerRebuild() {
        let selected = SpaceGoalSelection.select(from: [
            item(label: "DerivedData", sizeGB: 10, cleanupID: "xcode_derived_data"),
            item(label: "npm", sizeGB: 3, cleanupID: "npm_cache"),
            item(label: "pnpm", sizeGB: 3, cleanupID: "pnpm_store"),
        ], targetGB: 5)

        XCTAssertEqual(selected.map(\.cleanupID), ["npm_cache", "pnpm_store"])
    }

    func testGoalSelectionExcludesModelsAndAppRemovalFromBatchApproval() {
        let selected = SpaceGoalSelection.select(from: [
            item(label: "models", sizeGB: 40, cleanupID: "ollama_models", kind: "ai_cache"),
            item(label: "app", sizeGB: 20, cleanupID: "app_uninstall:example.app", kind: "application"),
            item(label: "npm", sizeGB: 1, cleanupID: "npm_cache"),
        ], targetGB: 10)

        XCTAssertEqual(selected.map(\.cleanupID), ["npm_cache"])
    }

    func testGoalSelectionKeepsTimedOutProjectResidueForBoundedPreview() {
        let selected = SpaceGoalSelection.select(from: [
            item(label: "npm", sizeGB: 1, cleanupID: "npm_cache"),
            item(
                label: "large node_modules",
                sizeGB: 0,
                cleanupID: "project_residue",
                kind: "project_residue",
                path: "/Users/test/App/node_modules",
                measureStatus: "timed_out"
            ),
        ], targetGB: 2)

        XCTAssertEqual(selected.map(\.cleanupID), ["npm_cache", "project_residue"])
        XCTAssertEqual(selected.last?.measureStatus, "timed_out")
    }

    func testSnapshotCarriesRecoveryOnlyProjectResidueCandidates() throws {
        let snapshot = try XCTUnwrap(StorageSnapshot(json: [
            "volume": [
                "mount": "/", "freeGB": 3, "usedGB": 97,
                "totalGB": 100, "usePercent": 97, "risk": "danger",
            ],
            "cleanupCandidates": [],
            "recoveryCandidates": [[
                "risk": "warning",
                "kind": "project_residue",
                "label": "Swift build",
                "sizeGB": 8,
                "path": "/Users/test/App/.build",
                "action": "정리",
                "measureStatus": "ok",
                "cleanupId": "project_residue",
            ]],
        ]))

        XCTAssertTrue(snapshot.cleanupCandidates.isEmpty)
        XCTAssertEqual(snapshot.recoveryCandidates.count, 1)
        XCTAssertEqual(snapshot.recoveryGB, 8, accuracy: 0.000_001)
    }

    func testProjectResidueRequestIsPathBoundAndRejectsProtocolControls() throws {
        let residue = item(
            label: "Swift build",
            sizeGB: 4,
            cleanupID: "project_residue",
            kind: "project_residue",
            path: "/Users/test/App/.build"
        )
        let request = try XCTUnwrap(CleanupExecutionRequest(item: residue))

        XCTAssertEqual(request.recipeID, "project_residue")
        XCTAssertEqual(request.target, "/Users/test/App/.build")
        XCTAssertTrue(String(decoding: request.protocolData, as: UTF8.self).contains("target\t/Users/test/App/.build"))

        let injected = item(
            label: "bad",
            sizeGB: 4,
            cleanupID: "project_residue",
            kind: "project_residue",
            path: "/Users/test/App/.build\nkind\tcache"
        )
        XCTAssertNil(CleanupExecutionRequest(item: injected))
    }

    func testPlanExecutesFreshReadyEntriesAndLeavesBlockedEntriesOut() throws {
        let ready = try preview(
            label: "npm", recipeID: "npm_cache", status: "ready",
            token: token("a"), estimatedKB: 1_024, approvalExpiresEpoch: 4_102_444_800
        )
        let blocked = try preview(label: "Swift", recipeID: "swiftpm_cache", status: "blocked", token: "", estimatedKB: 2_048)

        let executable = CleanupRecoveryPlan(
            baselineFreeGB: 4,
            desiredFreeGB: 20,
            entries: [CleanupPlanEntry(preview: ready, tier: .safe, request: nil)]
        )
        XCTAssertTrue(executable.canExecute)
        XCTAssertEqual(executable.estimatedKB, 1_024)

        let mixed = CleanupRecoveryPlan(
            baselineFreeGB: 4,
            desiredFreeGB: 20,
            entries: [
                CleanupPlanEntry(preview: ready, tier: .safe, request: nil),
                CleanupPlanEntry(preview: blocked, tier: .rebuild, request: nil),
            ]
        )
        XCTAssertTrue(mixed.canExecute)
        XCTAssertEqual(mixed.blockedEntries.count, 1)
    }

    func testPlanRequiresEnoughApprovalTimeBeforeStarting() throws {
        let expires = Int64(Date().timeIntervalSince1970) + 60
        let ready = try preview(
            label: "npm", recipeID: "npm_cache", status: "ready",
            token: token("a"), estimatedKB: 1_024, approvalExpiresEpoch: expires
        )
        let plan = CleanupRecoveryPlan(
            baselineFreeGB: 4,
            desiredFreeGB: 20,
            entries: [CleanupPlanEntry(preview: ready, tier: .safe, request: nil)]
        )

        XCTAssertTrue(plan.canExecute(at: Date(timeIntervalSince1970: TimeInterval(expires - 31))))
        XCTAssertFalse(plan.canExecute(at: Date(timeIntervalSince1970: TimeInterval(expires - 29))))
        XCTAssertFalse(plan.canExecute(at: Date(timeIntervalSince1970: TimeInterval(expires))))
    }

    func testUnmeasuredFinalSpaceNeverClaimsTheGoalWasMet() {
        let result = CleanupRecoveryResult(
            baselineFreeGB: 3,
            finalFreeGB: 30,
            desiredFreeGB: 20,
            freeSpaceMeasured: false,
            plannedCount: 2,
            items: [],
            stoppedAfterFailure: true,
            rescanScheduled: false
        )

        XCTAssertFalse(result.goalMet)
        XCTAssertEqual(result.actualGainGB, 0)
        XCTAssertEqual(result.skippedCount, 2)
    }

    private func item(
        label: String,
        sizeGB: Double,
        cleanupID: String,
        kind: String = "cache",
        path: String? = nil,
        measureStatus: String = "ok"
    ) -> StorageItem {
        StorageItem(json: [
            "risk": "warning",
            "kind": kind,
            "label": label,
            "sizeGB": sizeGB,
            "path": path ?? "/tmp/\(label)",
            "action": "정리",
            "note": "",
            "measureStatus": measureStatus,
            "cleanupId": cleanupID,
        ])!
    }

    private func preview(
        label: String,
        recipeID: String,
        status: String,
        token: String,
        estimatedKB: Int64,
        approvalExpiresEpoch: Int64 = 0
    ) throws -> CleanupPreview {
        try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\t\(status)
        recipeId\t\(recipeID)
        label\t\(label)
        estimatedKB\t\(estimatedKB)
        approvalToken\t\(token)
        approvalExpiresEpoch\t\(approvalExpiresEpoch)
        target\t/Users/test/\(recipeID)
        """))
    }

    private func token(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
