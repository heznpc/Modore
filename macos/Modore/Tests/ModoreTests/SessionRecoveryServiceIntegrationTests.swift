import Darwin
import Foundation
import XCTest
@testable import Modore

final class SessionRecoveryServiceIntegrationTests: XCTestCase {
    /// The installed app supplies sealed bytes, while checkout executions use
    /// relative paths. Run the sealed-FD branch with the real process runner:
    /// a hyphenated pin name used to make every installed-app call fail before
    /// Python launched, even though all model and checkout tests passed.
    func testSealedScriptsRoundTripAndResumePreparationThroughRealProcessRunner() async throws {
        let manager = FileManager.default
        // The backend rejects symlink path components. Foundation shortens
        // /private/var to /var, so use the physical temporary directory path.
        let physicalTemporary = try XCTUnwrap(realpath(manager.temporaryDirectory.path, nil))
        defer { free(physicalTemporary) }
        let root = URL(fileURLWithPath: String(cString: physicalTemporary))
            .appendingPathComponent("modore-session-pinned-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let records = home.appendingPathComponent(".codex/sessions/2026/09/27")
        try manager.createDirectory(at: records, withIntermediateDirectories: true)
        let sessionID = "11111111-2222-4333-8444-555555555555"
        let original = Data("""
        {"type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/fixture/project","git":{"branch":"main"}}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Synthetic integration fixture"}]}}

        """.utf8)
        let relative = ".codex/sessions/2026/09/27/rollout-fixture.jsonl"
        try original.write(to: home.appendingPathComponent(relative))
        let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))
        let context = RuntimeExecutionContext(
            runtimeRoot: root, outputRoot: root,
            configurationURL: root.appendingPathComponent("config.json"),
            usesBundledRuntime: true, runtimeRootIdentity: identity, outputRootIdentity: identity,
            signedBundleURL: nil,
            sealedRuntimeFiles: [
                "scripts/session_recovery.py": try Data(contentsOf: repository.appendingPathComponent("scripts/session_recovery.py")),
                "scripts/session_resume.py": try Data(contentsOf: repository.appendingPathComponent("scripts/session_resume.py")),
            ]
        )
        // There is deliberately no scripts/ directory at runtimeRoot. Success
        // requires execution of the exact bytes pinned above.
        let rawPlan = try await SessionRecoveryService.invoke(execution: context, script: "session_recovery.py",
            arguments: ["plan", "--home", home.path], timeout: 30)
        XCTAssertTrue(rawPlan.succeeded, "\(rawPlan.endState), status \(rawPlan.status): \(rawPlan.output)")
        guard case .plan(let plan) = try SessionRecoveryService.decode(rawPlan, operation: .plan) else {
            return XCTFail("Expected a session inventory")
        }
        XCTAssertTrue(plan.availableIDs.contains("codex.sessions"))
        XCTAssertEqual(plan.items.first { $0.id == "codex.sessions" }?.fileCount, 1)

        let bundle = root.appendingPathComponent("bundle")
        let backup = try await SessionRecoveryService.run(execution: context,
            operation: .backup(destination: bundle, itemIDs: ["codex.sessions"]), homeOverride: home).get()
        guard case .receipt(let backupReceipt) = backup else { return XCTFail("Expected backup receipt") }
        XCTAssertEqual(backupReceipt.status, "verified")
        XCTAssertEqual(backupReceipt.fileCount, 1)

        let verified = try await SessionRecoveryService.run(execution: context, operation: .verify(bundle: bundle)).get()
        guard case .receipt(let verifyReceipt) = verified else { return XCTFail("Expected verification receipt") }
        XCTAssertEqual(verifyReceipt.status, "verified")
        let restored = root.appendingPathComponent("restored")
        let restoration = try await SessionRecoveryService.run(execution: context,
            operation: .restore(bundle: bundle, destination: restored)).get()
        guard case .receipt(let restoreReceipt) = restoration else { return XCTFail("Expected restore receipt") }
        XCTAssertEqual(restoreReceipt.status, "restored")
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent(relative)), original)

        let rawSessions = try await SessionRecoveryService.invoke(execution: context, script: "session_resume.py",
            arguments: ["list", restored.path], timeout: 30)
        XCTAssertTrue(rawSessions.succeeded, "\(rawSessions.endState), status \(rawSessions.status): \(rawSessions.output)")
        let sessions = try JSONDecoder().decode(SessionResumeList.self,
            from: SessionRecoveryService.validatedData(rawSessions))
        XCTAssertTrue(sessions.isValid)
        XCTAssertEqual(sessions.sessions.map(\.sessionId), [sessionID])
        XCTAssertEqual(sessions.sessions.first?.workspace, "/fixture/project")

        let candidate = try XCTUnwrap(sessions.sessions.first)
        let workspace = root.appendingPathComponent("new workspace")
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let providerHome = root.appendingPathComponent("isolated provider")
        let fakeCLI = root.appendingPathComponent("fake codex cli")
        try """
        #!/bin/sh
        case "$*" in
          --version) printf '%s\\n' 'codex-cli 0.139.0' ;;
          'resume --help') printf '%s\\n' 'Usage: codex resume [SESSION_ID] -C, --cd <DIR> --no-daemon' ;;
          *) exit 91 ;;
        esac

        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        let rawPreparation = try await SessionRecoveryService.invoke(execution: context, script: "session_resume.py",
            arguments: ["prepare", restored.path, "--provider", candidate.provider,
                        "--session-id", candidate.sessionId, "--workspace", workspace.path,
                        "--provider-home", providerHome.path, "--cli-path", fakeCLI.path], timeout: 30)
        XCTAssertTrue(rawPreparation.succeeded, "\(rawPreparation.endState), status \(rawPreparation.status): \(rawPreparation.output)")
        let preparation = try JSONDecoder().decode(SessionResumePlan.self,
            from: SessionRecoveryService.validatedData(rawPreparation))
        XCTAssertEqual(preparation.status, "ready_to_try", preparation.limitations.joined(separator: "; "))
        XCTAssertTrue(preparation.matches(candidate, workspace: workspace, home: providerHome))
        XCTAssertTrue(preparation.matches(candidate,
            workspace: workspace.resolvingSymlinksInPath(), home: providerHome.resolvingSymlinksInPath()))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(preparation.preparedPaths.first))), original)
        XCTAssertTrue(manager.fileExists(atPath: providerHome.appendingPathComponent("modore-resume-plan.json").path))
        XCTAssertFalse(preparation.shellCommand.isEmpty)
    }
}
