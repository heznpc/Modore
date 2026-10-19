import Foundation
import XCTest
@testable import Modore

final class NativeCIWatchTests: XCTestCase {
    private func temporary() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return try NativeFileTree.resolved(path)
    }
    private func sample(_ id: Int = 1, conclusion: String = "failure") throws -> [String: Any] {
        ["series": "series", "repo": "owner/repo", "workflow": "CI", "branch": "main", "event": "push", "runId": id,
         "attempt": "\(id):1", "order": ["2026-10-19T00:00:00Z", id, 1], "url": "https://github.com/owner/repo/actions/runs/\(id)",
         "sha": "commit", "status": "completed", "conclusion": conclusion, "observedAt": "stamp", "streak": 1,
         "steps": ["test: 테스트"], "evidence": "log", "excerpt": "error: 테스트 실패", "signature": try NativeCIWatch.digest(["test: 테스트"]), "stepKey": try NativeCIWatch.digest("test")]
    }
    private func collection(_ samples: [[String: Any]]) -> [[String: Any]] {
        [["repo": "owner/repo", "observedAt": "stamp", "runsRead": samples.count, "limited": false, "error": NSNull(), "samples": samples]]
    }
    private func python(_ expression: String, value: Any) throws -> Any {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", "-c", "import base64,importlib.util,json,sys; s=importlib.util.spec_from_file_location('reference',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); q=json.loads(base64.b64decode(sys.argv[2])); print(json.dumps(" + expression + ",ensure_ascii=False))",
            package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/ci_watch.py").path, data.base64EncodedString()]
        process.standardOutput = output; try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try JSONSerialization.jsonObject(with: result, options: .fragmentsAllowed)
    }
    func testUnicodeIDsAndFailureReconciliationMatchPython() throws {
        let input: [String: Any] = ["state": NativeCIWatch.empty(), "collections": collection([try sample()])]
        let actual = try NativeCIWatch.reconcile(input["state"] as! [String: Any], collections: input["collections"] as! [[String: Any]], notify: true, timestamp: "stamp")
        let expected = try python("m.reconcile(q['state'],q['collections'],notify=True,timestamp='stamp')", value: input)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual, options: .sortedKeys), try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys))
        let value: [Any] = ["테스트 😀", ["é", "\n", "slash/path"], NSNull(), true, 12]
        XCTAssertEqual(try NativeCIWatch.digest(value), try python("m.digest(q)", value: value) as? String)
    }
    func testOnlyNewerSuccessInSameLaneRecoversAnIncident() throws {
        var state = try NativeCIWatch.reconcile(NativeCIWatch.empty(), collections: collection([try sample(2)]), notify: true)
        state = try NativeCIWatch.reconcile(state, collections: collection([try sample(1, conclusion: "success")]), notify: true)
        XCTAssertEqual((state["incidents"] as? [[String: Any]])?.first?["state"] as? String, "open")
        state = try NativeCIWatch.reconcile(state, collections: collection([try sample(3, conclusion: "cancelled")]), notify: true)
        XCTAssertEqual((state["incidents"] as? [[String: Any]])?.first?["state"] as? String, "open")
        state = try NativeCIWatch.reconcile(state, collections: collection([]), notify: true)
        XCTAssertEqual((state["incidents"] as? [[String: Any]])?.first?["tracking"] as? String, "not_observed")
        state = try NativeCIWatch.reconcile(state, collections: collection([try sample(4, conclusion: "success")]), notify: true)
        XCTAssertEqual((state["incidents"] as? [[String: Any]])?.first?["state"] as? String, "recovered")
        XCTAssertEqual((state["events"] as? [[String: Any]])?.map { $0["kind"] as! String }, ["recovered"])
    }
    func testClosedPRDoesNotBecomeGreenRecovery() throws {
        var state = try NativeCIWatch.reconcile(NativeCIWatch.empty(), collections: collection([try sample()]))
        var closed = try sample(2, conclusion: "success"); closed["activePR"] = false
        state = try NativeCIWatch.reconcile(state, collections: collection([closed]), notify: true)
        XCTAssertEqual((state["incidents"] as? [[String: Any]])?.first?["state"] as? String, "inactive")
        XCTAssertTrue((state["events"] as? [[String: Any]] ?? []).isEmpty)
    }
    func testErrorCollectionPreservesKnownFailureAndDoesNotAlert() throws {
        let initial = try NativeCIWatch.reconcile(NativeCIWatch.empty(), collections: collection([try sample()]))
        let failed: [[String: Any]] = [["repo": "owner/repo", "error": "offline", "samples": [], "runsRead": 0, "limited": false, "observedAt": NSNull()]]
        let result = try NativeCIWatch.reconcile(initial, collections: failed, notify: true)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: result["incidents"]!, options: .sortedKeys), try JSONSerialization.data(withJSONObject: initial["incidents"]!, options: .sortedKeys))
        XCTAssertTrue((result["events"] as? [[String: Any]] ?? []).isEmpty)
    }
    func testStatusDoesNotCreateStateAndAcknowledgementDoesNotQueryGitHub() throws {
        let root = try temporary().appendingPathComponent("ci")
        let status = try NativeCIWatch.invoke(["action": "status"], root: root)
        XCTAssertEqual(status["initialized"] as? Bool, false)
        XCTAssertFalse(NativeFileTree.exists(root))
        _ = try NativeCIWatch.invoke(["action": "ack", "ids": []], root: root, api: { _, _ in XCTFail("ack must not query GitHub"); return [:] })
        XCTAssertTrue(NativeFileTree.exists(root.appendingPathComponent("state.json")))
    }
    func testPrivacyScrubbingAndInvalidRepositoryNames() throws {
        let result = NativeCIWatch.scrub("\u{1b}[31merror: /Users/username/project person@example.com token=secret-value ghp_abc123 https://example.org/private\u{1b}[0m")
        for secret in ["username", "person@example.com", "secret-value", "ghp_abc123", "https://example.org"] { XCTAssertFalse(result.contains(secret)) }
        XCTAssertThrowsError(try NativeCIWatch.slug("owner/../repo"))
        XCTAssertThrowsError(try NativeCIWatch.slug("owner/repo\n"))
    }
    func testCollectorIgnoresTeardownErrorsAfterFailingStep() throws {
        let run: [String: Any] = ["id": 1, "run_attempt": 1, "conclusion": "failure"]
        let output = try NativeCIWatch.evidence(api: { endpoint, raw in
            if raw { return "2026-10-19T00:00:00Z error: expected failure\n##[error]Process completed with exit code 1.\nerror: teardown database\n" }
            XCTAssertTrue(endpoint.contains("/attempts/1/jobs"))
            return ["jobs": [["id": 2, "name": "test", "conclusion": "failure", "steps": [["name": "run tests", "conclusion": "failure"]]]]]
        }, repo: "owner/repo", run: run)
        XCTAssertTrue((output["excerpt"] as? String ?? "").contains("expected failure"))
        XCTAssertFalse((output["excerpt"] as? String ?? "").contains("teardown"))
    }
    func testNativeCommandStreamsBinaryInputAndBoundsOutputAndTimeout() throws {
        let input = Data(repeating: 0xa5, count: 128 * 1024)
        let result = try NativeCommand.run("/bin/cat", [], input: input, timeout: 3, limit: 256 * 1024)
        XCTAssertEqual(result.status, 0); XCTAssertEqual(result.output, input)
        XCTAssertThrowsError(try NativeCommand.run("/usr/bin/yes", [], timeout: 3, limit: 1024))
        let started = Date()
        XCTAssertThrowsError(try NativeCommand.run("/bin/sleep", ["10"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
