import XCTest
@testable import Modore

final class WorktreeEvidenceTests: XCTestCase {
    func testPartialFailureDoesNotDecodeAsClean() {
        let item = ScreeWorktreeItem(json: [
            "path": "/fixture/repo", "verdict": "protected",
            "dirty": NSNull(), "unpushed_commits": 2,
            "errors": [["operation": "status", "reason": "command_timeout"]],
        ])
        XCTAssertNil(item.dirty)
        XCTAssertEqual(item.unpushedCommits, 2)
        XCTAssertTrue(item.reasonText.contains("시간 초과"))
        XCTAssertFalse(item.reasonText.contains("Git 변경 없음"))
    }

    func testIgnoredAndSessionEvidenceDoNotClaimActiveUseOrDeletionSafety() {
        let item = ScreeWorktreeItem(json: [
            "path": "/fixture/repo", "verdict": "protected", "dirty": false,
            "unpushed_commits": 0, "ignored_entries": 3,
            "session_references": 2, "checked_out": true, "locked": true,
        ])
        XCTAssertTrue(item.reasonText.contains("ignored"))
        XCTAssertTrue(item.reasonText.contains("세션 기록 참조 2개"))
        XCTAssertTrue(item.reasonText.contains("현재 사용 여부 미검증"))
        XCTAssertTrue(item.reasonText.contains("삭제 판단 보류"))
        XCTAssertTrue(item.reasonText.contains("잠금"))
    }

    func testOfflineVolumeAndPermissionsHaveDifferentReasons() {
        let offline = ScreeGitFailure(json: ["operation": "open", "reason": "volume_unavailable"])
        let denied = ScreeGitFailure(json: ["operation": "open", "reason": "permission_denied"])
        XCTAssertTrue(offline.label.contains("외장 볼륨"))
        XCTAssertTrue(denied.label.contains("권한"))
        XCTAssertNotEqual(offline.label, denied.label)
    }

    func testSquashUncertaintyAndCheckedOutBranchReachScreen() {
        let branch = ScreeBranchEvidence(json: [
            "repo": "/fixture/repo", "branch": "feature",
            "merge_state": "not_ancestor_merge_unknown", "checked_out_path": "/fixture/wt",
            "merge_base": "refs/remotes/origin/main",
        ])
        XCTAssertTrue(branch.reasonText.contains("squash 병합 여부 미검증"))
        XCTAssertTrue(branch.reasonText.contains("체크아웃 등록됨 · 보존"))
        XCTAssertFalse(branch.reasonText.contains("미병합"))
    }

    func testTimeoutRetainedResultDecodesCoverageAndBranches() {
        let discovery = ScreeWorktreeDiscovery(json: [
            "scope": "session-metadata", "truncated": true, "stop_reason": "worker_timeout",
            "branches": [["repo": "/fixture/repo", "branch": "main"]],
            "errors": [["operation": "worktree", "reason": "budget_exhausted"]],
        ])
        XCTAssertEqual(discovery.branches.count, 1)
        XCTAssertEqual(discovery.errors.count, 1)
        XCTAssertTrue(discovery.coverageText.contains("결과를 유지"))
        XCTAssertFalse(discovery.globalComplete)
    }
}
