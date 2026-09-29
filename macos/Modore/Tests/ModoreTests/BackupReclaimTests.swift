import Foundation
import XCTest
@testable import Modore

final class BackupReclaimTests: XCTestCase {
    private let local = URL(fileURLWithPath: "/Users/example/Documents")
    private let backup = URL(fileURLWithPath: "/Volumes/Example/Backup/Documents")
    private let rowID = String(repeating: "b", count: 32)
    private let planID = String(repeating: "a", count: 48)

    private func planObject() -> [String: Any] {
        ["schemaVersion": 1, "planID": planID, "localRoot": local.path, "backupRoot": backup.path,
         "createdAt": 1_000, "expiresAt": 4_600, "complete": true, "processCheck": true,
         "identicalBytes": 5, "warnings": [], "coverage": "fixture",
         "rows": [["id": rowID, "path": "file.txt", "status": "identical", "reason": "fixture", "bytes": 5]]]
    }

    private func decode(_ object: [String: Any]) throws -> BackupReclaimPlan {
        try JSONDecoder().decode(BackupReclaimPlan.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testPlanBindsRootsAndRejectsTraversalOrDuplicateIDs() throws {
        let object = planObject()
        let valid = try decode(object)
        XCTAssertTrue(valid.matches(local: local, backup: backup))
        XCTAssertFalse(valid.matches(local: backup, backup: local))
        var duplicated = object
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        duplicated["rows"] = rows + rows
        XCTAssertFalse(try decode(duplicated).matches(local: local, backup: backup))
        var traversal = object
        var row = rows[0]
        row["path"] = "../private.txt"
        traversal["rows"] = [row]
        XCTAssertFalse(try decode(traversal).matches(local: local, backup: backup))
    }

    func testProtectedRowsCannotBeSelected() throws {
        var object = planObject()
        object["rows"] = [["id": rowID, "path": ".codex", "status": "protected", "reason": "fixture"]]
        XCTAssertFalse(try decode(object).rows[0].selectable)
    }

    func testReceiptMustMatchSelectionAndDeletedByteTotal() throws {
        let plan = try decode(planObject())
        var object: [String: Any] = ["schemaVersion": 1, "planID": planID, "localRoot": local.path,
            "backupRoot": backup.path, "status": "finished", "receiptPath": "/fixture/receipt.json",
            "journalPath": "/fixture/journal.jsonl", "deletedBytes": 5,
            "freeBytesBefore": 10, "freeBytesAfter": 15,
            "items": [["id": rowID, "path": "file.txt", "status": "deleted", "bytes": 5]]]
        func receipt() throws -> BackupReclaimReceipt {
            try JSONDecoder().decode(BackupReclaimReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertTrue(try receipt().matches(plan, selected: [rowID]))
        XCTAssertFalse(try receipt().matches(plan, selected: []))
        object["deletedBytes"] = 50
        XCTAssertFalse(try receipt().matches(plan, selected: [rowID]))
    }

    func testSealedBackendRunsThroughRealProcessRunner() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("modore-reclaim-pin-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))
        let context = RuntimeExecutionContext(runtimeRoot: root, outputRoot: root,
            configurationURL: root.appendingPathComponent("config.json"), usesBundledRuntime: true,
            runtimeRootIdentity: identity, outputRootIdentity: identity, signedBundleURL: nil,
            sealedRuntimeFiles: ["scripts/backup_reclaim.py": try Data(contentsOf: repository.appendingPathComponent("scripts/backup_reclaim.py"))])
        let result = try await SessionRecoveryService.invoke(execution: context, script: "backup_reclaim.py",
            arguments: ["--help"], timeout: 30)
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertTrue(result.output.contains("compare"))
    }
}
