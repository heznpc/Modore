import XCTest
@testable import Modore

final class ScreeModelsTests: XCTestCase {
    func testSessionIndexDecodesIncompleteStoreCoverageWithoutDroppingRows() throws {
        let data = Data("""
        {
          "total": 1,
          "sessions": [],
          "coverage": {
            "complete": false,
            "stores": [
              {"store":"Claude Desktop","status":"unreadable","count":0,"unrecognized":0},
              {"store":"Codex","status":"ok","count":1,"unrecognized":2}
            ]
          }
        }
        """.utf8)

        let index = try JSONDecoder().decode(SessionIndex.self, from: data)

        XCTAssertEqual(index.total, 1)
        XCTAssertEqual(index.coverage.stores.count, 2)
        XCTAssertEqual(
            index.coverage.warningText,
            "일부 로컬 대화 저장소를 끝까지 확인하지 못했습니다: Claude Desktop 읽기 실패 · Codex 형식 미인식 2개. 현재 목록을 전체 기록으로 단정하지 않습니다."
        )
    }

    func testCompleteSessionIndexCoverageHasNoWarning() {
        let coverage = SessionIndexCoverage(
            complete: true,
            stores: [
                SessionIndexStoreCoverage(
                    store: "Claude",
                    status: "ok",
                    count: 3,
                    unrecognized: 0
                )
            ]
        )

        XCTAssertNil(coverage.warningText)
    }
    private func expiringJson(ownerDeleted: Any? = nil) -> [String: Any] {
        var session: [String: Any] = [
            "tool": "Claude",
            "workspace": "/Users/test/Projects/proj",
            "source": "/Users/test/.claude/projects/-p/s.jsonl",
            "days_left": 2,
            "size_bytes": 1024,
            "story_alive": true,
        ]
        if let ownerDeleted {
            session["owner_deleted"] = ownerDeleted
        }
        return session
    }

    func testExpiringSessionCarriesTheOwnerDeletedVerdict() {
        XCTAssertTrue(ScreeExpiringSession(json: expiringJson(ownerDeleted: true)).ownerDeleted)
        XCTAssertFalse(ScreeExpiringSession(json: expiringJson(ownerDeleted: false)).ownerDeleted)
    }

    func testAnExpiringSessionWithoutTheFlagIsNotTreatedAsDeleted() {
        // An older scree that does not emit the key must never make the app
        // claim the owner threw a conversation away.
        XCTAssertFalse(ScreeExpiringSession(json: expiringJson()).ownerDeleted)
    }

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

    func testWorktreeDiscoveryDecodesBoundedMetadataCoverageHonestly() throws {
        let report = try XCTUnwrap(ScreeReport(json: [
            "worktrees": [
                "items": [],
                "scope": "session-metadata",
                "global_complete": false,
                "observed_workspaces": 454,
                "unreadable": 3,
                "truncated": true,
            ],
        ]))

        XCTAssertEqual(report.worktreeDiscovery.scope, "session-metadata")
        XCTAssertFalse(report.worktreeDiscovery.globalComplete)
        XCTAssertEqual(report.worktreeDiscovery.observedWorkspaces, 454)
        XCTAssertEqual(report.worktreeDiscovery.unreadable, 3)
        XCTAssertTrue(report.worktreeDiscovery.truncated)
        XCTAssertTrue(report.worktreeDiscovery.coverageText.contains("454"))
        XCTAssertTrue(report.worktreeDiscovery.coverageText.contains("디스크 전체 검색 결과가 아닙니다"))
        XCTAssertTrue(report.worktreeDiscovery.coverageText.contains("3곳"))
        XCTAssertFalse(report.worktreeDiscovery.emptyStateText.contains("등록된"))
    }

    func testUnknownRegistrationAndVanishedRegistryEntriesRemainDistinct() throws {
        var unknown = worktreeJson(verdict: "protected")
        unknown["registered"] = NSNull()
        let report = try XCTUnwrap(ScreeReport(json: [
            "worktrees": [
                "items": [unknown],
                "registered_missing": [[
                    "repo": "/Users/test/repo",
                    "path": "/Users/test/repo/.claude/worktrees/vanished",
                ]],
            ],
        ]))

        let item = try XCTUnwrap(report.worktreeItems.first)
        XCTAssertNil(item.registered)
        XCTAssertTrue(item.reasonText.contains("등록 여부 확인 실패"))
        XCTAssertEqual(report.registeredMissing.first?.displayLabel, "vanished")
    }

    func testMissingWorktreeCoverageNeverDefaultsToGlobalCompleteness() throws {
        let report = try XCTUnwrap(ScreeReport(json: ["worktrees": ["items": []]]))

        XCTAssertFalse(report.worktreeDiscovery.globalComplete)
        XCTAssertTrue(report.worktreeDiscovery.coverageText.contains("제한"))
    }

    // scree.py's build_lineage already casefold-deduplicates and reports
    // has_git per distinct path -- this is the field MothballPage filters
    // on to pick archive-scan candidates, so it must decode correctly.
    func testLineagePathDecodesExistenceAndGitPresence() throws {
        let report = try XCTUnwrap(ScreeReport(json: [
            "lineage": ["paths": [
                ["path": "/Users/test/repo-a", "exists": true, "has_git": true],
                ["path": "/Users/test/plain-folder", "exists": true, "has_git": false],
            ]],
        ]))

        XCTAssertEqual(report.lineagePaths.count, 2)
        let repo = try XCTUnwrap(report.lineagePaths.first { $0.path == "/Users/test/repo-a" })
        XCTAssertTrue(repo.exists)
        XCTAssertTrue(repo.hasGit)
        XCTAssertEqual(repo.caseVariants, [])

        let plain = try XCTUnwrap(report.lineagePaths.first { $0.path == "/Users/test/plain-folder" })
        XCTAssertFalse(plain.hasGit)
    }

    func testLineagePathDecodesCaseVariantsWhenPresent() throws {
        let report = try XCTUnwrap(ScreeReport(json: [
            "lineage": ["paths": [
                ["path": "/Users/test/Paper/ploidy", "exists": true, "has_git": true,
                 "case_variants": ["/Users/test/Paper/ploidy", "/Users/test/paper/ploidy"]],
            ]],
        ]))

        let item = try XCTUnwrap(report.lineagePaths.first)
        XCTAssertEqual(item.caseVariants, ["/Users/test/Paper/ploidy", "/Users/test/paper/ploidy"])
    }
}
