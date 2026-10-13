import XCTest
@testable import Modore

final class WorkResourcePolicyTests: XCTestCase {
    func testConnectionUsesProviderSessionNotListRowID() throws {
        let json = """
        {"tool":"Codex","source":"/fixture/rollout.jsonl","workspace":"/fixture/project",
         "kind":"session","sizeBytes":1,"lastActive":"now","sessionId":"session-123"}
        """
        let entry = try JSONDecoder().decode(SessionIndexEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.id, "codex:session-123")
        XCTAssertEqual(entry.resourceIdentity, ResourceSessionIdentity(provider: "codex", session: "session-123"))
        let request = ResourceConnectionRequest(id: "allowed", fingerprint: "fixture", project: entry.workspace,
            identity: try XCTUnwrap(entry.resourceIdentity))
        let data = try JSONEncoder().encode(request)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(decoded, request.dictionary as? [String: String])
        XCTAssertEqual(decoded["action"], "bind")
        XCTAssertEqual(decoded["session"], "session-123")
        let volume = ResourceConnectionRequest(id: "volume", fingerprint: "fixture", project: entry.workspace,
            identity: try XCTUnwrap(entry.resourceIdentity), isSimulator: false)
        XCTAssertEqual(volume.action, "claim") // Volume occupancy remains an explicit usage lease.
        // Optional bridge artifact consumed by the offline actual-Codex probe.
        if let output = ProcessInfo.processInfo.environment["MODORE_PROBE_REQUEST_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    func testSnapshotPreservesPersistentBindingAndGuardCoverage() throws {
        let json = """
        {"observedAt":1,"warnings":[],"coverage":"fixture","resources":[
          {"id":"sim","kind":"simulator","name":"fixture","runtime":"ios","deviceType":"phone",
           "state":"Shutdown","path":"/fixture","fingerprint":"fp","available":true,"preferred":false,
           "duplicates":[],"leases":[],"expiredLeases":[],"processes":[],
           "bindings":[{"provider":"codex","session":"raw","project":"/project","resourceID":"sim"}]}],
         "hookStatus":[{"provider":"codex","configured":true,"disabled":false,"recentlyObserved":false,
           "trustStatus":"untrusted","simulatorGuard":{"configured":true,"hostEnforcementVerified":false,"coverage":"shell and MCP"}}]}
        """
        let snapshot = try JSONDecoder().decode(WorkResourceSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.resources[0].bindings?.first?.session, "raw")
        XCTAssertEqual(snapshot.hookStatus?.first?.trustStatus, "untrusted")
        XCTAssertEqual(snapshot.hookStatus?.first?.simulatorGuard?.coverage, "shell and MCP")
    }
}
