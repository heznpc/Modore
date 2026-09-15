import Foundation
import XCTest
@testable import Modore

final class QuotaWorkStateTests: XCTestCase {
    private let nativeID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let taskID = "11111111-2222-4333-8444-555555555555"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(root: String = "/profiles/main") -> [String: Any] {
        let ms = now.timeIntervalSince1970 * 1000
        return ["schemaVersion": 1, "generatedAtMs": ms, "expiresAtMs": ms + 600_000,
                "accounts": [["provider": "codex", "account": "main", "label": "Main",
                              "profileKey": QuotaWorkSnapshot.digest(root), "collectionState": "recent-success",
                              "windows": [["bucket": "weekly", "label": "Weekly", "remainingPercent": 90,
                                           "resetsAtMs": ms + 300_000, "observedAtMs": ms,
                                           "freshness": "fresh", "validUntilMs": ms + 600_000]]]],
                "tasks": [["id": taskID, "provider": "codex", "account": "main", "bucket": "weekly",
                           "label": "Example", "state": "ready", "registeredAtMs": ms - 600_000, "readyAtMs": ms,
                           "sessionKey": QuotaWorkSnapshot.sessionKey(provider: "codex", account: "main", nativeID: nativeID)]]]
    }

    private func snapshot(_ value: [String: Any]) throws -> QuotaWorkSnapshot {
        try XCTUnwrap(QuotaWorkStateService.decode(JSONSerialization.data(withJSONObject: value)).snapshot)
    }

    private func session(source: String = "/profiles/main/sessions/example.jsonl", provider: String = "Codex") throws -> SessionIndexEntry {
        let value: [String: Any] = ["tool": provider, "source": source, "workspace": "/project",
                                  "kind": "session", "sizeBytes": 100, "lastActive": "2026-09-13",
                                  "sessionId": nativeID]
        return try JSONDecoder().decode(SessionIndexEntry.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testMatchesProviderAccountSessionAndProfileWithoutReadingConversation() throws {
        let state = try snapshot(fixture())
        XCTAssertEqual(state.task(for: try session())?.id, taskID)
        XCTAssertNil(state.task(for: try session(source: "/profiles/other/sessions/example.jsonl")))
        XCTAssertNil(state.task(for: try session(source: "/profiles/main/nested-profile/sessions/example.jsonl")))
        XCTAssertEqual(state.task(for: try session(source: "/profiles/main/archived_sessions/example.jsonl"))?.id, taskID)
        XCTAssertNil(state.task(for: try session(provider: "Claude")))
        XCTAssertEqual(state.tasks[0].reviewURL?.absoluteString, "quotapie://resume/\(taskID)")
        // Shared test vector must stay identical to QuotaPie's SHA-256 contract.
        XCTAssertEqual(QuotaWorkSnapshot.sessionKey(provider: "codex", account: "main", nativeID: nativeID.uppercased()),
                       "8b9b3daf99a133703e893df419501bd9dd4709bc067375c36f1ecd31c81fdb00")
    }

    func testCopiedSessionsAndMultipleAccountsNeverChooseAnArbitraryMatch() throws {
        let state = try snapshot(fixture())
        let first = try session()
        let second = try session(source: "/profiles/main/sessions/copy.jsonl")
        XCTAssertNil(state.session(for: taskID, in: [first, second]))
        var value = fixture()
        var tasks = try XCTUnwrap(value["tasks"] as? [[String: Any]])
        var copy = tasks[0]
        copy["id"] = "99999999-2222-4333-8444-555555555555"
        tasks.append(copy)
        value["tasks"] = tasks
        XCTAssertNil(try snapshot(value).task(for: first))
    }

    func testExpiryFutureClockAndInvalidDocuments() throws {
        let state = try snapshot(fixture())
        XCTAssertTrue(state.isCurrent(now: now))
        XCTAssertFalse(state.isCurrent(now: now.addingTimeInterval(600)))
        XCTAssertFalse(state.isCurrent(now: now.addingTimeInterval(-61)))
        for key in ["schemaVersion", "expiresAtMs"] {
            var value = fixture(); value[key] = 42
            XCTAssertNil(QuotaWorkStateService.decode(try JSONSerialization.data(withJSONObject: value)).snapshot)
        }
        var duplicate = fixture()
        duplicate["tasks"] = (duplicate["tasks"] as! [[String: Any]]) + (duplicate["tasks"] as! [[String: Any]])
        XCTAssertNil(QuotaWorkStateService.decode(try JSONSerialization.data(withJSONObject: duplicate)).snapshot)
    }

    func testFileReaderRejectsSymlinksAndDistinguishesMissingFromInvalid() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        if case .missing = QuotaWorkStateService.read(from: file) {} else { XCTFail("expected missing") }
        try JSONSerialization.data(withJSONObject: fixture()).write(to: file)
        XCTAssertNotNil(QuotaWorkStateService.read(from: file).snapshot)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        if case .invalid = QuotaWorkStateService.read(from: link) {} else { XCTFail("expected invalid") }
    }

    func testWorkRouteSelectsTaskButNeverStartsStorageScan() throws {
        let route = try XCTUnwrap(ModoreRoute(url: URL(string: "modore://work/quota-task/\(taskID)")!))
        XCTAssertEqual(route, .quotaTask(taskID))
        XCTAssertFalse(route.shouldStartStorageScan(hasStorageData: false, isBusy: false))
        for suffix in ["?execute=true", "#approval", "/extra"] {
            XCTAssertNil(ModoreRoute(url: URL(string: "modore://work/quota-task/\(taskID)\(suffix)")!))
        }
        XCTAssertNil(ModoreRoute(url: URL(string: "modore://work/quota-task/not-a-uuid")!))
    }
}
