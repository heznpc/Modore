import Foundation
import XCTest
@testable import Modore

@MainActor
final class SkillInventoryServiceTests: XCTestCase {
    private func snapshot(_ marker: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "items": [], "backups": [], "warnings": [], "scope": marker, "observed": 1,
        ])
    }

    private func model(reviewOnly: Bool = false) async -> ScanModel {
        let model = ScanModel(automaticallyScansStaleResults: false,
            projectRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            existingResultsLoader: { _ in
                LoadedScanResult(content: ScanContent(root: [:]), deepScanAt: nil,
                    storageHistory: [], displayedStorageEntry: nil, storageChange: nil,
                    freeSpaceSamples: [], diagnostic: nil)
            }, storageWatchEvidenceLoader: { nil }, cleanupReviewOnly: reviewOnly)
        for task in model.cancelTrackedApplicationTasks() { await task.value }
        return model
    }

    func testModeSwitchPublishesOnlyAfterSuccessfulDecode() async throws {
        let model = await model()
        let installed = try snapshot("installed")
        let demo = try snapshot("demo")
        var fail = true
        var requests: [Bool] = []
        let service = SkillInventoryService { _, _, usingDemo in
            requests.append(usingDemo)
            if usingDemo && fail { return Data("{}".utf8) }
            return usingDemo ? demo : installed
        }
        let loaded = await service.perform(["action": "status"], model: model)
        XCTAssertTrue(loaded)
        let failed = await service.switchMode(model: model)
        XCTAssertFalse(failed)
        XCTAssertFalse(service.demo)
        XCTAssertEqual(service.snapshot?.scope, "installed")
        fail = false
        let changed = await service.switchMode(model: model)
        XCTAssertTrue(changed)
        XCTAssertTrue(service.demo)
        XCTAssertEqual(service.snapshot?.scope, "demo")
        XCTAssertEqual(requests, [false, true, true])
    }

    func testFailedComparisonDoesNotReusePreviousDiff() async throws {
        let model = await model()
        var valid = true
        let service = SkillInventoryService { _, _, _ in
            valid ? Data(#"{"diff":"old comparison"}"#.utf8) : Data("{}".utf8)
        }
        let first = await service.perform(["action": "compare"], model: model)
        XCTAssertTrue(first)
        XCTAssertEqual(service.diff, "old comparison")
        valid = false
        let second = await service.perform(["action": "compare"], model: model)
        XCTAssertFalse(second)
        XCTAssertEqual(service.diff, "")
        XCTAssertFalse(service.error.isEmpty)
    }

    func testReviewOnlyRejectsLiveMutationEvenWithoutCallerFlag() async {
        let model = await model(reviewOnly: true)
        var calls = 0
        let service = SkillInventoryService { _, _, _ in
            calls += 1
            return Data()
        }
        for action in ["disable", "restore"] {
            let performed = await service.perform(["action": action], model: model)
            XCTAssertFalse(performed)
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(service.error, CleanupExecutionService.reviewOnlyMessage)
        XCTAssertEqual(model.terminationSafetyState, .safe)
    }

    func testDemoMutationUsesDemoRootAndDefersTermination() async throws {
        let model = await model(reviewOnly: true)
        let payload = try snapshot("demo")
        var mutations = 0
        let service = SkillInventoryService { _, request, demo in
            XCTAssertTrue(demo)
            if request["action"] as? String == "disable" {
                mutations += 1
                XCTAssertTrue(model.cleanupInFlight)
                XCTAssertEqual(model.terminationSafetyState, .destructiveCleanupInProgress)
            }
            return payload
        }
        let switched = await service.switchMode(model: model)
        XCTAssertTrue(switched)
        let performed = await service.perform(["action": "disable"], model: model)
        XCTAssertTrue(performed)
        XCTAssertEqual(mutations, 1)
        XCTAssertFalse(model.cleanupInFlight)
        XCTAssertEqual(model.terminationSafetyState, .safe)
    }

    func testFailedMutationRefreshesReceiptsAndReleasesTransaction() async throws {
        let model = await model()
        let payload = try snapshot("partial receipt")
        var requests: [String] = []
        let service = SkillInventoryService { _, request, _ in
            let action = request["action"] as? String ?? ""
            requests.append(action)
            if action == "restore" { throw RetirementError("fixture conflict") }
            return payload
        }
        let performed = await service.perform(["action": "restore"], model: model)
        XCTAssertFalse(performed)
        XCTAssertEqual(requests, ["restore", "status"])
        XCTAssertEqual(service.snapshot?.scope, "partial receipt")
        XCTAssertEqual(service.error, "fixture conflict")
        XCTAssertFalse(service.busy)
        XCTAssertFalse(model.cleanupInFlight)
        XCTAssertEqual(model.terminationSafetyState, .safe)
    }

    func testExistingCleanupBlocksMutationWithoutClearingItsLock() async {
        let model = await model()
        model.cleanupInFlight = true
        var calls = 0
        let service = SkillInventoryService { _, _, _ in calls += 1; return Data() }
        let performed = await service.perform(["action": "disable"], model: model)
        XCTAssertFalse(performed)
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(model.cleanupInFlight)
        XCTAssertFalse(service.error.isEmpty)
    }

    func testTerminationCancelsReadsAndWaitsForTheirCleanup() async throws {
        for action in ["status", "probe", "compare", "mode"] {
            let model = await model()
            let payload = try snapshot("cancelled read")
            var release: CheckedContinuation<Void, Never>?
            var entered = false
            var cancelled = false
            var completions = 0
            var terminationReplies = 0
            let service = SkillInventoryService { _, _, _ in
                entered = true
                await withCheckedContinuation { release = $0 }
                cancelled = Task.isCancelled
                return payload
            }
            if action == "mode" {
                service.startModeSwitch(model: model) { completions += 1 }
            } else {
                service.startRead(["action": action], model: model) { completions += 1 }
            }
            for _ in 0..<100 where !entered { await Task.yield() }
            XCTAssertTrue(entered, action)
            XCTAssertTrue(model.cancelApplicationTasksForTermination { terminationReplies += 1 })
            await Task.yield()
            XCTAssertEqual(terminationReplies, 0, "termination must await cleanup: \(action)")
            release?.resume()
            for _ in 0..<100 where terminationReplies == 0 { await Task.yield() }
            XCTAssertTrue(cancelled, action)
            XCTAssertEqual(terminationReplies, 1, action)
            XCTAssertEqual(completions, 0, action)
            XCTAssertNil(service.snapshot, action)
            XCTAssertFalse(service.demo, action)
            XCTAssertFalse(service.busy, action)
        }
    }
}
