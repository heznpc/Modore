import XCTest
@testable import Modore

final class ScreeModelsTests: XCTestCase {
    private func worktreeJson(
        strayCheckout: Bool? = nil,
        path: String = "/Users/test/IdeaProjects/repo/.claude/worktrees/wt1",
        verdict: String = "protected",
        dirty: Any = false,
        unpushedCommits: Any = 2
    ) -> [String: Any] {
        var item: [String: Any] = [
            "path": path,
            "repo": "/Users/test/IdeaProjects/repo",
            "branch": "feat1",
            "registered": true,
            "dirty": dirty,
            "unpushed_commits": unpushedCommits,
            "last_commit": "2026-08-01",
            "verdict": verdict,
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

    // scripts/scree.py's _worktree_verdict can now produce "unreadable" when
    // a git call fails partway through a check (see test_scree.py). Before
    // this, the view's own rendering treated anything that wasn't literally
    // "protected" as "재구축 가능" (rebuildable) -- so even a correctly-
    // computed "unreadable" verdict from the backend fix would still have
    // displayed as rebuildable here, silently undoing it.
    func testUnreadableVerdictGetsItsOwnLabelAndSymbolNotRebuildable() throws {
        let report = try XCTUnwrap(ScreeReport(json: [
            "worktrees": ["items": [worktreeJson(verdict: "unreadable")]],
        ]))
        let item = try XCTUnwrap(report.worktreeItems.first)

        XCTAssertEqual(item.verdictLabel, "확인 불가")
        XCTAssertNotEqual(item.verdictLabel, "재구축 가능")
        XCTAssertEqual(item.verdictSymbolName, "questionmark.circle")
    }

    func testProtectedAndRebuildableVerdictsKeepTheirExistingLabels() throws {
        let report = try XCTUnwrap(ScreeReport(json: [
            "worktrees": ["items": [
                worktreeJson(path: "/Users/test/protected", verdict: "protected"),
                worktreeJson(path: "/Users/test/rebuildable", verdict: "rebuildable"),
            ]],
        ]))

        let protectedItem = try XCTUnwrap(report.worktreeItems.first { $0.verdict == "protected" })
        let rebuildableItem = try XCTUnwrap(report.worktreeItems.first { $0.verdict == "rebuildable" })
        XCTAssertEqual(protectedItem.verdictLabel, "보호 대상")
        XCTAssertEqual(protectedItem.verdictSymbolName, "lock.fill")
        XCTAssertEqual(rebuildableItem.verdictLabel, "재구축 가능")
        XCTAssertEqual(rebuildableItem.verdictSymbolName, "arrow.triangle.2.circlepath")
    }

    // dirty/unpushed_commits collapse null (git call failed) to false/0 on
    // decode (JsonRead.bool/int), which would otherwise make reasonText
    // print "clean" for an item whose actual git state was never confirmed.
    // reasonText must defer to the already-authoritative verdict instead of
    // re-deriving a second, less honest description from those collapsed
    // booleans.
    func testReasonTextDefersToVerdictWhenUnreadableInsteadOfShowingClean() throws {
        let report = try XCTUnwrap(ScreeReport(json: [
            "worktrees": ["items": [worktreeJson(verdict: "unreadable", dirty: false, unpushedCommits: 0)]],
        ]))
        let item = try XCTUnwrap(report.worktreeItems.first)

        XCTAssertNotEqual(item.reasonText, "clean")
        XCTAssertTrue(item.reasonText.contains("재검사") || item.reasonText.contains("실패"))
    }
}
