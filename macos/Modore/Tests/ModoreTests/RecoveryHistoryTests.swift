import Foundation
import XCTest
@testable import Modore

final class RecoveryHistoryTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modore-history-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func plan() throws -> CleanupRecoveryPlan {
        let preview = try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tready
        recipeId\tnpm_cache
        label\tnpm cache
        estimatedKB\t1024
        approvalToken\t\(String(repeating: "a", count: 64))
        approvalExpiresEpoch\t4102444800
        target\t/private/test/cache
        """))
        return CleanupRecoveryPlan(baselineFreeBytes: 10 * StorageBytes.perGiB,
                                   requestedGainBytes: StorageBytes.perGiB,
                                   entries: [CleanupPlanEntry(preview: preview, tier: .safe, request: nil)])
    }

    func testRoundTripPreservesGoalTargetsSignedResultAndReceiptWithoutToken() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = RecoveryHistory(plan: try plan())
        record.phase = .finished
        record.approvedAt = Date()
        record.finalFreeBytes = 9 * StorageBytes.perGiB
        record.items = [RecoveryHistory.Item(CleanupRecoveryItemResult(
            recipeID: "npm_cache", requestTarget: "", label: "npm cache", status: "complete",
            reclaimedBytes: 1024, physicalDeltaBytes: -1024, receipt: "/private/test/receipt.tsv", detail: ""))]
        try RecoveryHistoryStore.save(record, in: root)
        let loaded = try XCTUnwrap(RecoveryHistoryStore.load(in: root).first)
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded.desiredFreeBytes, 11 * StorageBytes.perGiB)
        XCTAssertEqual(loaded.actualChangeBytes, -StorageBytes.perGiB)
        XCTAssertFalse(loaded.goalMet)
        XCTAssertEqual(loaded.entries[0].targets, ["/private/test/cache"])
        let data = try Data(contentsOf: RecoveryHistoryStore.url(in: root))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("approvalToken"))
        XCTAssertFalse(text.contains(String(repeating: "a", count: 64)))
        let attributes = try FileManager.default.attributesOfItem(atPath: RecoveryHistoryStore.url(in: root).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRestartDoesNotInferCompletionFromAnUnfinishedExecution() throws {
        for phase in [RecoveryHistory.Phase.approved, .running] {
            var record = RecoveryHistory(plan: try plan())
            record.phase = phase
            record.approvedAt = Date()
            record.activeEntryID = record.entries[0].id
            let restored = record.afterRestart
            XCTAssertEqual(restored.phase, .interrupted)
            XCTAssertNil(restored.finalFreeBytes)
            XCTAssertFalse(restored.goalMet)
            XCTAssertEqual(restored.activeEntryID, record.entries[0].id)
            XCTAssertTrue(restored.detail.contains("자동 실행하지 않습니다"))
        }
    }

    func testMeasuredZeroAndMissingFinalValueRemainDistinct() throws {
        var record = RecoveryHistory(plan: try plan())
        record.phase = .finished
        XCTAssertNil(record.actualChangeBytes)
        record.finalFreeBytes = record.baselineFreeBytes
        XCTAssertEqual(record.actualChangeBytes, 0)
        record.finalFreeBytes = record.desiredFreeBytes
        XCTAssertTrue(record.goalMet)
    }

    func testCheckpointUpdatesSamePlanWithoutDuplicatingIt() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = RecoveryHistory(plan: try plan())
        try RecoveryHistoryStore.save(record, in: root)
        record.phase = .approved
        record.approvedAt = Date()
        try RecoveryHistoryStore.save(record, in: root)
        XCTAssertEqual(try RecoveryHistoryStore.load(in: root), [record])
    }

    func testCorruptUnknownVersionAndSymlinkHistoryAreNotOverwritten() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = RecoveryHistoryStore.url(in: root)
        let record = RecoveryHistory(plan: try plan())
        for text in ["corrupt", "{\"version\":99,\"records\":[]}"] {
            let original = Data(text.utf8)
            try original.write(to: destination)
            XCTAssertThrowsError(try RecoveryHistoryStore.save(record, in: root))
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
        try FileManager.default.removeItem(at: destination)
        let target = root.appendingPathComponent("protected")
        try Data("protected".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        XCTAssertThrowsError(try RecoveryHistoryStore.load(in: root))
        XCTAssertThrowsError(try RecoveryHistoryStore.save(record, in: root))
        XCTAssertEqual(try String(contentsOf: target), "protected")
    }

    func testInvalidBytesAndUnmatchedResultAreRejected() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = RecoveryHistory(plan: try plan())
        record.finalFreeBytes = -1
        XCTAssertThrowsError(try RecoveryHistoryStore.save(record, in: root))
        record.finalFreeBytes = nil
        record.items = [RecoveryHistory.Item(CleanupRecoveryItemResult(
            recipeID: "unrelated", requestTarget: "", label: "", status: "complete",
            reclaimedBytes: nil, physicalDeltaBytes: nil, receipt: "", detail: ""))]
        XCTAssertThrowsError(try RecoveryHistoryStore.save(record, in: root))
    }

    func testFullJournalDoesNotDiscardEarlierPlans() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let records = try (0..<RecoveryHistoryStore.maximumRecords).map { _ in
            RecoveryHistory(plan: try plan())
        }
        let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
        let original = try JSONSerialization.data(withJSONObject: ["version": 1, "records": rows])
        try original.write(to: RecoveryHistoryStore.url(in: root))
        XCTAssertThrowsError(try RecoveryHistoryStore.save(RecoveryHistory(plan: plan()), in: root))
        XCTAssertEqual(try Data(contentsOf: RecoveryHistoryStore.url(in: root)), original)
        XCTAssertEqual(try RecoveryHistoryStore.load(in: root).count, RecoveryHistoryStore.maximumRecords)
    }
}
