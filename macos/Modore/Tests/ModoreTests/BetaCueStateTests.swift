import Foundation
import XCTest
@testable import Modore

final class BetaCueStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thread = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private func fixture() -> [String: Any] {
        ["schemaVersion": 1, "producer": "BetaCue", "generatedAt": "2027-01-15T08:00:00Z",
         "expiresAt": "2027-01-15T08:00:20Z", "connectionID": "opaque-account",
         "runtime": ["instanceID": "runtime-1", "pid": 123, "state": "running", "heartbeatAt": "2027-01-15T08:00:00Z"],
         "apps": [["id": "app-1", "name": "Example", "bundleID": "example.app",
                   "status": ["code": "ready", "headline": "Ready", "description": "Selected group is ready."],
                   "fetchedAt": "2027-01-15T07:59:59Z", "partial": false]],
         "watch": ["id": "watch-1", "appID": "app-1", "appName": "Example", "buildID": "build-1",
                   "goal": ["channel": "internal", "groupID": "group-1", "groupName": "Team"],
                   "phase": "ready", "headline": "Ready for Team", "detail": "", "startedAt": "2027-01-15T07:50:00Z",
                   "observedAt": "2027-01-15T08:00:00Z", "evidence": ["Selected group attached."], "openURL": "betacue://watch"],
         "workRecords": [["id": "record-1", "title": "Upload check", "url": "codex://threads/\(thread)",
                          "createdAt": "2027-01-15T07:50:00Z"]], "issues": []]
    }
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testDecodesPinnedTargetEvidenceAndExpiresWithoutNewRead() throws {
        let snapshot = try XCTUnwrap(BetaCueStateService.decode(data(fixture())).snapshot)
        XCTAssertEqual(snapshot.watch?.buildID, "build-1")
        XCTAssertEqual(snapshot.watch?.goal.groupID, "group-1")
        XCTAssertEqual(snapshot.watch?.evidence, ["Selected group attached."])
        XCTAssertEqual(snapshot.workRecords.first?.destination?.absoluteString, "codex://threads/\(thread)")
        XCTAssertTrue(snapshot.isCurrent(now: now))
        XCTAssertFalse(snapshot.isCurrent(now: now.addingTimeInterval(20)))
        XCTAssertFalse(snapshot.isCurrent(now: now.addingTimeInterval(-61)))
        var stopped = fixture()
        var runtime = stopped["runtime"] as! [String: Any]; runtime["state"] = "stopped"; stopped["runtime"] = runtime
        XCTAssertFalse(try XCTUnwrap(BetaCueStateService.decode(data(stopped)).snapshot).isCurrent(now: now))
    }

    func testRejectsUnsupportedSchemaLongLifetimeAndDuplicateRecords() throws {
        for (key, value) in [("schemaVersion", 2 as Any), ("producer", "Other" as Any),
                             ("expiresAt", "2027-01-16T08:00:00Z" as Any)] {
            var invalid = fixture(); invalid[key] = value
            XCTAssertNil(BetaCueStateService.decode(try data(invalid)).snapshot)
        }
        var duplicate = fixture(); duplicate["workRecords"] = (duplicate["workRecords"] as! [[String: Any]]) + (duplicate["workRecords"] as! [[String: Any]])
        XCTAssertNil(BetaCueStateService.decode(try data(duplicate)).snapshot)
    }

    func testPrivateBoundedReaderRejectsSymlinksAndPublicPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        if case .missing = BetaCueStateService.read(from: file) {} else { XCTFail("Expected missing") }
        try data(fixture()).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertNotNil(BetaCueStateService.read(from: file).snapshot)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        if case .invalid = BetaCueStateService.read(from: link) {} else { XCTFail("Expected invalid symlink") }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        if case .invalid = BetaCueStateService.read(from: file) {} else { XCTFail("Expected invalid mode") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data(repeating: 32, count: BetaCueStateService.maximumBytes + 1).write(to: file)
        if case .invalid = BetaCueStateService.read(from: file) {} else { XCTFail("Expected invalid size") }
    }

    func testNavigationURLsCannotBecomeCommandsOrFileReads() {
        XCTAssertNotNil(BetaCueStateService.safeURL("betacue://watch", watch: true))
        XCTAssertNotNil(BetaCueStateService.safeURL("betacue://app?id=123", watch: true))
        XCTAssertNil(BetaCueStateService.safeURL("betacue://watch?start=true", watch: true))
        var authenticatedURL = URLComponents(string: "https://chatgpt.com/c/\(thread)")!
        authenticatedURL.user = "fixture"
        for raw in ["file:///private/transcript", "javascript:alert(1)", "codex://threads/\(thread)?execute=1",
                    "https://chatgpt.com.evil.test/c/\(thread)", authenticatedURL.string!] {
            XCTAssertNil(BetaCueStateService.safeURL(raw), raw)
        }
        XCTAssertEqual(ModoreRoute(url: URL(string: "modore://work/betacue")!), .betaCue)
        XCTAssertFalse(ModoreRoute.betaCue.shouldStartStorageScan(hasStorageData: false, isBusy: false))
        XCTAssertNil(ModoreRoute(url: URL(string: "modore://work/betacue?start=true")!))
    }
}
