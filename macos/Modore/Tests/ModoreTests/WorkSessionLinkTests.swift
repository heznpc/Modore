import Foundation
import XCTest
@testable import Modore

final class WorkSessionLinkTests: XCTestCase {
    private let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    private func session(source: String, provider: String = "Codex", kind: String = "session") throws -> SessionIndexEntry {
        let value: [String: Any] = ["tool": provider, "source": source, "workspace": "/missing/project",
            "workspaceExists": false, "kind": kind, "sizeBytes": 1, "lastActive": "2026-10-21", "sessionId": id]
        return try JSONDecoder().decode(SessionIndexEntry.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testRoundTripNavigationWithoutQuotaTaskOrExistingWorkspace() throws {
        let link = try XCTUnwrap(WorkSessionLink(provider: "codex", sessionID: id.uppercased()))
        let route = try XCTUnwrap(ModoreRoute(url: URL(string: "modore://work/session/codex/\(id)")!))
        XCTAssertEqual(route, .session(link))
        XCTAssertFalse(route.shouldStartStorageScan(hasStorageData: false, isBusy: false))
        let row = try session(source: "/profile/sessions/a.jsonl")
        XCTAssertEqual(link.resolve(in: [row]), row)
        XCTAssertEqual(link.quotaPieURL.absoluteString, "quotapie://session/\(id)")
    }

    func testNeverChoosesAnAmbiguousProfileOrWrongProvider() throws {
        let link = try XCTUnwrap(WorkSessionLink(provider: "codex", sessionID: id))
        XCTAssertNil(link.resolve(in: []))
        XCTAssertNil(link.resolve(in: [try session(source: "/a"), try session(source: "/b")]))
        XCTAssertNil(link.resolve(in: [try session(source: "/a", provider: "Claude")]))
        XCTAssertNil(link.resolve(in: [try session(source: "/a", kind: "workspace_state")]))
    }

    func testRejectsExecutionParametersPathsAndMalformedIDs() throws {
        for suffix in ["?execute=true", "#restore", "/", "/extra"] {
            XCTAssertNil(ModoreRoute(url: URL(string: "modore://work/session/codex/\(id)\(suffix)")!))
        }
        for value in ["modore://work/session/codex/no-id", "modore://work/session/claude/\(id)",
                      "modore://user@work/session/codex/\(id)", "modore://work:42/session/codex/\(id)",
                      "modore://work/%73ession/codex/\(id)", "modore://work//session/codex/\(id)"] {
            XCTAssertNil(ModoreRoute(url: URL(string: value)!))
        }
    }
}
