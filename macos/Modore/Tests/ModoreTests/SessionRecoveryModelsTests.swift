import Darwin
import Foundation
import XCTest
@testable import Modore

final class SessionRecoveryModelsTests: XCTestCase {
    func testBackupUsesArgumentArrayAndExplicitSensitiveConsent() throws {
        let path = URL(fileURLWithPath: "/Volumes/Backup drive/$(touch nope)'bundle")
        let args = try SessionRecoveryOperation.backup(destination: path, itemIDs: ["codex.sessions"])
            .arguments(homeOverride: URL(fileURLWithPath: "/tmp/fixture home"))
        XCTAssertEqual(args, ["backup", "--destination", path.path, "--items-json",
                              "[\"codex.sessions\"]", "--include-sensitive", "--home", "/tmp/fixture home"])
        XCTAssertThrowsError(try SessionRecoveryOperation.backup(destination: path, itemIDs: []).arguments())
        XCTAssertThrowsError(try SessionRecoveryOperation.backup(destination: path, itemIDs: ["same", "same"]).arguments())
        XCTAssertEqual(try SessionRecoveryOperation.verify(bundle: path).arguments(homeOverride: path), ["verify", path.path])
    }

    func testOnlyMatchingVerifiedReceiptIsAccepted() {
        let bundle = URL(fileURLWithPath: "/tmp/bundle")
        let good = SessionRecoveryReceipt(schemaVersion: 1, status: "verified", bundle: bundle.path,
            fileCount: 2, totalBytes: 45, providers: ["Codex"], warnings: [], restoredRoot: nil)
        let partial = SessionRecoveryReceipt(schemaVersion: 1, status: "partial", bundle: bundle.path,
            fileCount: 2, totalBytes: 45, providers: ["Codex"], warnings: [], restoredRoot: nil)
        XCTAssertTrue(SessionRecoveryOperation.verify(bundle: bundle).accepts(good))
        XCTAssertFalse(SessionRecoveryOperation.verify(bundle: URL(fileURLWithPath: "/tmp/other")).accepts(good))
        XCTAssertFalse(SessionRecoveryOperation.verify(bundle: bundle).accepts(partial))
        XCTAssertFalse(SessionRecoveryOperation.restore(bundle: bundle, destination: bundle).accepts(good))
    }

    func testCancelledTimedOutAndTruncatedOutputCannotReportSuccess() {
        for state in [ProcessEndState.cancelled, .timedOut, .outputLimit] {
            let result = CapturedProcessResult(status: 0, output: "{}", endState: state, outputTruncated: false)
            XCTAssertThrowsError(try SessionRecoveryService.validatedData(result))
        }
        XCTAssertThrowsError(try SessionRecoveryService.validatedData(
            CapturedProcessResult(status: 0, output: "{}", endState: .exited, outputTruncated: true)))
    }

    func testPlanRejectsDuplicateInventoryAndOmitsUnavailableSelections() {
        let item = SessionRecoveryItem(id: "codex.sessions", provider: "Codex", label: "Sessions",
            source: "/tmp/.codex/sessions", kind: "directory", bytes: 15, fileCount: 1, available: true, reason: "")
        let duplicate = SessionRecoveryPlan(schemaVersion: 1, status: "planned", items: [item, item],
            warnings: [], excluded: [], coverage: [])
        XCTAssertFalse(duplicate.isValid)
        let missing = SessionRecoveryItem(id: "missing", provider: "Codex", label: "Unavailable",
            source: "/tmp/missing", kind: "directory", bytes: 500, fileCount: 5, available: false, reason: "")
        let plan = SessionRecoveryPlan(schemaVersion: 1, status: "planned", items: [item, missing],
            warnings: [], excluded: [], coverage: [])
        XCTAssertTrue(plan.isValid)
        XCTAssertEqual(plan.availableIDs, ["codex.sessions"])
        XCTAssertEqual(plan.selectedBytes(["codex.sessions", "missing"]), 15)
    }

    func testResumeRequiresSelectedSessionAndIsolatedEnvironment() {
        let session = SessionResumeCandidate(id: "codex:123", provider: "codex", sessionId: "123",
            label: "fixture", workspace: nil, sourcePath: ".codex/sessions/a.jsonl")
        let home = URL(fileURLWithPath: "/Volumes/SSD/new home")
        let workspace = URL(fileURLWithPath: "/Volumes/SSD/it's a $(project)")
        let plan = SessionResumePlan(provider: "codex", sessionId: "123",
            argv: ["/usr/local/bin/codex", "resume", "123", "-C", workspace.path],
            environment: ["CODEX_HOME": home.path, "HOME": home.appendingPathComponent("user-home").path],
            workingDirectory: workspace.path, status: "ready_to_try", limitations: [], providerHome: home.path,
            sourcePaths: ["a"], preparedPaths: ["b"], cliVersion: "1.0")
        XCTAssertTrue(plan.matches(session, workspace: workspace, home: home))
        XCTAssertFalse(plan.matches(session, workspace: workspace, home: URL(fileURLWithPath: "/tmp/other")))
        XCTAssertTrue(plan.shellCommand.contains("it'\\''s a $(project)"))
        XCTAssertTrue(plan.shellCommand.contains("CODEX_HOME='/Volumes/SSD/new home'"))
        XCTAssertTrue(plan.shellCommand.contains("HOME='/Volumes/SSD/new home/user-home'"))
    }

    func testUnsupportedResumeDecodesWithoutPathsAndHasNoCommand() throws {
        let data = Data(#"{"provider":"claude","sessionId":"123","argv":[],"environment":{},"workingDirectory":null,"status":"unsupported","limitations":["CLI unavailable"],"providerHome":null,"sourcePaths":[],"preparedPaths":[]}"#.utf8)
        let plan = try JSONDecoder().decode(SessionResumePlan.self, from: data)
        let session = SessionResumeCandidate(id: "claude:123", provider: "claude", sessionId: "123",
            label: "fixture", workspace: nil, sourcePath: "a")
        XCTAssertTrue(plan.matches(session, workspace: URL(fileURLWithPath: "/tmp/project"), home: URL(fileURLWithPath: "/tmp/home")))
        XCTAssertEqual(plan.shellCommand, "")
        XCTAssertNil(plan.cliVersion)
    }

    func testResumeMatchesPhysicalAndFoundationVarAliasesOnBothSides() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("modore-resume-alias-\(UUID())")
        try manager.createDirectory(at: root.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("home/user-home"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let physicalRoot = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physicalRoot) }
        let session = SessionResumeCandidate(id: "codex:123", provider: "codex", sessionId: "123",
            label: "fixture", workspace: nil, sourcePath: "a")
        let path = String(cString: physicalRoot)
        XCTAssertTrue(path.hasPrefix("/private/var/"))
        let plan = SessionResumePlan(provider: "codex", sessionId: "123",
            argv: ["/usr/local/bin/codex", "resume", "123"],
            environment: ["CODEX_HOME": path + "/home", "HOME": path + "/home/user-home"],
            workingDirectory: path + "/workspace", status: "ready_to_try", limitations: [],
            providerHome: path + "/home", sourcePaths: [], preparedPaths: [], cliVersion: nil)
        for prefix in [path, String(path.dropFirst("/private".count))] {
            XCTAssertTrue(plan.matches(session,
                workspace: URL(fileURLWithPath: prefix + "/workspace"),
                home: URL(fileURLWithPath: prefix + "/home")))
        }
        XCTAssertFalse(plan.matches(session,
            workspace: URL(fileURLWithPath: path + "/other-workspace"),
            home: URL(fileURLWithPath: path + "/home")))
    }
}
