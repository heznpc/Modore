import XCTest
@testable import Modore

final class ScreeModelsTests: XCTestCase {
    private func worktreeJson(strayCheckout: Bool? = nil, path: String = "/Users/test/IdeaProjects/repo/.claude/worktrees/wt1") -> [String: Any] {
        var item: [String: Any] = [
            "path": path,
            "repo": "/Users/test/IdeaProjects/repo",
            "branch": "feat1",
            "registered": true,
            "dirty": false,
            "unpushed_commits": 2,
            "last_commit": "2026-08-01",
            "verdict": "protected",
            "evidence": "preview",
        ]
        if let strayCheckout {
            item["stray_checkout"] = strayCheckout
        }
        return item
    }

    // scree.py never writes stray_checkout: false explicitly -- the key is
    // simply absent on a real worktree item (see collect_worktrees in
    // scripts/scree.py). Absence must decode the same as an explicit false.
    func testStrayCheckoutDefaultsFalseWhenKeyIsAbsent() throws {
        let report = try XCTUnwrap(ScreeReport(json: ["worktrees": ["items": [worktreeJson(strayCheckout: nil)]]]))
        let item = try XCTUnwrap(report.worktreeItems.first)

        XCTAssertFalse(item.strayCheckout)
        XCTAssertEqual(item.displayLabel, "wt1")
    }

    func testStrayCheckoutDecodesAndProducesADistinctLabel() throws {
        let report = try XCTUnwrap(ScreeReport(json: [
            "worktrees": ["items": [worktreeJson(strayCheckout: true, path: "/Users/test/IdeaProjects/repo")]],
        ]))
        let item = try XCTUnwrap(report.worktreeItems.first)

        XCTAssertTrue(item.strayCheckout)
        // The primary checkout's own directory name ("repo") must not render
        // identically to how a disposable secondary worktree would -- that's
        // the entire bug this fixes: before this, both cases showed nothing
        // but the bare directory name under a section header that says
        // "agent worktrees".
        XCTAssertEqual(item.displayLabel, "메인 체크아웃 · repo")
        XCTAssertNotEqual(item.displayLabel, item.pathLastComponent)
    }

    func testMixedWorktreeAndStrayCheckoutItemsAreIndividuallyDistinguished() throws {
        let report = try XCTUnwrap(ScreeReport(json: [
            "worktrees": ["items": [
                worktreeJson(strayCheckout: true, path: "/Users/test/IdeaProjects/repo"),
                worktreeJson(strayCheckout: nil, path: "/Users/test/IdeaProjects/repo/.claude/worktrees/wt1"),
            ]],
        ]))

        XCTAssertEqual(report.worktreeItems.count, 2)
        let stray = try XCTUnwrap(report.worktreeItems.first { $0.strayCheckout })
        let worktree = try XCTUnwrap(report.worktreeItems.first { !$0.strayCheckout })
        XCTAssertTrue(stray.displayLabel.hasPrefix("메인 체크아웃"))
        XCTAssertFalse(worktree.displayLabel.hasPrefix("메인 체크아웃"))
    }
}
