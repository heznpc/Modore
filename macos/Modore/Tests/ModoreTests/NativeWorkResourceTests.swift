import Darwin
import Foundation
import XCTest
@testable import Modore

final class NativeWorkResourceTests: XCTestCase {
    private let id = "12345678-1234-1234-1234-123456789ABC"
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return try NativeFileTree.resolved(root)
    }
    private func row(state: String = "Shutdown") throws -> [String: Any] {
        try XCTUnwrap(try NativeWorkResources.simulatorRows(["devices": ["runtime": [["udid": id, "name": "fixture iPhone", "state": state,
            "deviceTypeIdentifier": "iPhone-fixture", "isAvailable": true, "dataPath": "/tmp/fixture-device"]]]]).first)
    }
    private func manager(_ home: URL) throws -> NativeWorkResources {
        let manager = NativeWorkResources(home: home), fixture = try row()
        manager.deviceInventory = { [fixture] }; manager.volumeInventory = { ([], []) }; manager.observation = { _ in ([:], []) }; return manager
    }
    private func request(_ home: URL, _ action: String, session: String = "codex:thread") throws -> [String: Any] {
        ["action": action, "id": id, "fingerprint": try row()["fingerprint"]!, "project": home.path, "session": session, "provider": "codex"]
    }
    func testNativeClaimRemainsReadableAndReleasableByPythonHooks() throws {
        let home = try temporary(), manager = try manager(home)
        _ = try manager.invoke(request(home, "claim"))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/work_resources.py")
        let code = "import importlib.util,json,sys; from pathlib import Path; spec=importlib.util.spec_from_file_location('reference',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); print(json.dumps(m.dispatch({'action':'release','provider':'codex','session':'thread'},Path(sys.argv[2]))))"
        let result = try NativeCommand.run("/usr/bin/python3", ["-I", "-B", "-c", code, script.path, manager.registry.root.path])
        XCTAssertEqual(result.status, 0, result.errorText)
        let snapshot = try manager.snapshot(), rows = try XCTUnwrap(snapshot["resources"] as? [[String: Any]])
        XCTAssertEqual((rows.first?["leases"] as? [[String: Any]])?.count, 0)
        _ = try JSONDecoder().decode(WorkResourceSnapshot.self, from: JSONSerialization.data(withJSONObject: snapshot))
    }
    func testBindingsPersistAndDifferentProvidersRemainDistinct() throws {
        let home = try temporary(), manager = try manager(home)
        _ = try manager.invoke(request(home, "bind"))
        let state = try XCTUnwrap(try manager.registry.read("leases.json"))
        XCTAssertEqual((state["bindings"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse(NativeWorkResources.same(["session": "thread", "provider": "claude"], session: "thread", provider: "codex"))
        _ = try manager.invoke(request(home, "unbind"))
        XCTAssertEqual((try manager.registry.read("leases.json")?["bindings"] as? [[String: Any]])?.count, 0)
    }
    func testExpiredUnreleasedLeasesStillProtectOtherSessionsAndShutdown() throws {
        let home = try temporary(), manager = try manager(home)
        _ = try manager.invoke(request(home, "claim"))
        var state = try XCTUnwrap(try manager.registry.read("leases.json")), leases = try XCTUnwrap(state["leases"] as? [[String: Any]])
        leases[0]["updatedAt"] = 1; leases[0]["expiresAt"] = 901; state["leases"] = leases
        try manager.registry.save(state, name: "leases.json")
        XCTAssertThrowsError(try manager.invoke(request(home, "claim", session: "codex:other")))
        var called = false; manager.command = { _, _, _ in called = true; return Data() }
        XCTAssertThrowsError(try manager.invoke(request(home, "shutdown"))); XCTAssertFalse(called)
    }
    func testMutationRevalidatesFingerprintAndRecordsExactUDIDAndPostState() throws {
        let home = try temporary(), manager = try manager(home)
        var request = try request(home, "boot"), called: [String] = []
        request["fingerprint"] = "stale"
        manager.command = { _, args, _ in called = args; return Data() }
        XCTAssertThrowsError(try manager.invoke(request)); XCTAssertTrue(called.isEmpty)
        request["fingerprint"] = try row()["fingerprint"]!
        let shutdown = try row(), booted = try row(state: "Booted"); var observed = 0
        manager.deviceInventory = { observed += 1; return [observed == 1 ? shutdown : booted] }
        let result = try manager.invoke(request)
        XCTAssertEqual(called, ["simctl", "boot", id]); XCTAssertEqual((result["result"] as? [String: Any])?["verified"] as? Bool, true)
        XCTAssertTrue(NativeFileTree.exists(URL(fileURLWithPath: try XCTUnwrap(result["receipt"] as? String))))
        XCTAssertThrowsError(try manager.invoke(["action": "delete-duplicate", "id": id]))
    }
    func testNULSeparatedObservationPreservesNewlinesInPaths() throws {
        let row = try row(), data = Data(("p42\0cfixture\0\nfcwd\0n/tmp/project\0\nf3\0n/tmp/fixture-device/file\nname\0\n").utf8)
        let evidence = NativeWorkResources.processEvidence(data, rows: [row])
        XCTAssertEqual(evidence[id]?.first?["cwd"] as? String, "/tmp/project")
        XCTAssertEqual(evidence[id]?.first?["pid"] as? Int, 42)
    }
    func testHookConfigurationAloneNeverClaimsObservedTrustedExecution() throws {
        let home = try temporary(), codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let command = "/tmp/example-modore resources hook --provider codex"
        let handlers: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": command]]]], "Stop": [["hooks": [["type": "command", "command": command]]]]]]
        try JSONSerialization.data(withJSONObject: handlers).write(to: codex.appendingPathComponent("hooks.json"))
        let hooks = NativeResourceHooks.status([:], home: home)
        XCTAssertEqual(hooks.first?["recentlyObserved"] as? Bool, false)
        XCTAssertEqual(try NativeResourceHooks.words("'/tmp/space path/modore' resources hook --provider codex"), ["/tmp/space path/modore", "resources", "hook", "--provider", "codex"])
        XCTAssertThrowsError(try NativeResourceHooks.words("'unterminated"))
    }
}
