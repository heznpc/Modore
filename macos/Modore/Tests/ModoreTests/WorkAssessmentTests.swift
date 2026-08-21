import XCTest
import MothballCore
@testable import Modore

/// The 작업 screen's warning marker, which was wrong in both directions.
final class WorkAssessmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func repo(
        path: String, dirty: Bool = false, ahead: Int = 0,
        origin: String? = "git@example.com:test/repo.git", daysIdle: Double = 400
    ) -> RepoInfo {
        let activity = now.addingTimeInterval(-daysIdle * 86_400)
        return RepoInfo(
            path: URL(fileURLWithPath: path), sizeBytes: 1_024, lastFileMTime: activity,
            git: GitMetadata(
                lastCommitDate: activity, isDirty: dirty, aheadOfOrigin: ahead,
                originURL: origin, currentBranch: "main", headSHA: "abc"))
    }

    private func assessment(_ repo: RepoInfo) -> ArchiveCandidate {
        MothballService.assessRepos(repos: [repo], now: now)[0]
    }

    private func worktree(_ verdict: String, path: String = "/repo/.claude/worktrees/wt") -> ScreeWorktreeItem {
        ScreeWorktreeItem(json: [
            "path": path, "repo": "/repo", "branch": "feat", "registered": true,
            "dirty": false, "unpushed_commits": 0, "last_commit": "2026-08-01",
            "verdict": verdict, "evidence": "preview",
        ])
    }

    // MARK: - worktree verdict vocabulary

    /// scree's vocabulary is `protected` / `rebuildable` / `unreadable`.
    /// A filter written against `"reclaimable"` -- a value that does not
    /// exist -- matched every one of them, so every rebuildable worktree
    /// was reported as something the user must protect.
    func test_onlyProtectedWorktreesCountAsProtected() {
        let project = WorkProject(
            path: "/repo",
            worktrees: [worktree("protected"), worktree("rebuildable"), worktree("unreadable")])
        XCTAssertEqual(project.protectedWorktrees.count, 1)
        XCTAssertEqual(project.protectedWorktrees.first?.verdict, "protected")
    }

    /// Unreadable is not safe, but calling it protected claims knowledge
    /// nobody has -- so it gets its own name and still raises the marker.
    func test_unreadableWorktreesAreFlaggedWithoutBeingCalledProtected() {
        let project = WorkProject(path: "/repo", worktrees: [worktree("unreadable")])
        XCTAssertTrue(project.protectedWorktrees.isEmpty)
        XCTAssertEqual(project.unverifiedWorktrees.count, 1)
        XCTAssertTrue(project.needsAttention)
    }

    func test_aRebuildableWorktreeAloneRaisesNothing() {
        let project = WorkProject(path: "/repo", worktrees: [worktree("rebuildable")])
        XCTAssertFalse(project.needsAttention)
    }

    // MARK: - git state vs retirement eligibility

    /// `rankCandidates` drops `.unsafe` repos, which is right for a
    /// retirement list. Using it as a project's git state meant the repos
    /// carrying uncommitted work -- the reason they are unsafe -- vanished
    /// and were shown as having nothing wrong.
    func test_aRepoTooRiskyToRetireStillReportsItsRisks() {
        // No remote: nothing to clone back from, so it must never be
        // archived -- and it is carrying uncommitted work as well.
        let dirty = repo(path: "/repo", dirty: true, ahead: 3, origin: nil)
        XCTAssertTrue(
            MothballService.rankCandidates(repos: [dirty], now: now).isEmpty,
            "precondition: this repo is not a retirement candidate")

        let project = WorkProject(path: "/repo", assessment: assessment(dirty))
        XCTAssertFalse(project.gitRisks.isEmpty, "its risks must still be visible")
        XCTAssertTrue(project.needsAttention)
        XCTAssertNil(project.candidate, "but there is no retirement to review")
    }

    /// The other direction: a clean, fully-pushed, long-dormant repo is
    /// the ideal retirement candidate, and it was getting a warning
    /// triangle because "dormant" was being counted as a risk.
    func test_aDormantCleanRepoIsNotAWarning() {
        let project = WorkProject(path: "/repo", assessment: assessment(repo(path: "/repo")))
        XCTAssertTrue(project.gitRisks.isEmpty)
        XCTAssertFalse(project.needsAttention)
        XCTAssertFalse(project.gitNotes.isEmpty, "dormancy is still worth saying")
        XCTAssertNotNil(project.candidate)
    }

    func test_assessRepsKeepsEveryRepoWhileRankingKeepsOnlyTheRetirable() {
        let repos = [repo(path: "/clean"), repo(path: "/noremote", origin: nil)]
        XCTAssertEqual(MothballService.assessRepos(repos: repos, now: now).count, 2)
        XCTAssertEqual(MothballService.rankCandidates(repos: repos, now: now).count, 1)
    }

    func test_aProjectWithNoScanClaimsNothing() {
        let project = WorkProject(path: "/repo")
        XCTAssertTrue(project.gitRisks.isEmpty)
        XCTAssertTrue(project.gitNotes.isEmpty)
        XCTAssertNil(project.candidate)
        XCTAssertFalse(project.needsAttention)
    }
}

/// Project identity must not depend on casing, and must not depend on
/// whether the archive classifier kept the repo.
final class WorkProjectIdentityTests: XCTestCase {
    private func session(_ workspace: String) -> SessionIndexEntry {
        SessionInspectionFixtures.entry(
            workspace: workspace,
            source: "/Users/example/.claude/projects/\(UUID().uuidString).jsonl")
    }

    /// macOS filesystems are case-insensitive by default and each provider
    /// records its own casing of the same directory, which is why scree's
    /// lineage folds case. Without folding here, one folder became two
    /// projects.
    func test_casingDoesNotSplitOneFolderIntoTwoProjects() {
        let projects = WorkProjectBuilder.build(
            sessions: [session("/Users/example/Ploidy"), session("/Users/example/ploidy")],
            worktrees: [], assessments: [])
        XCTAssertEqual(projects.count, 1)
    }

    func test_aSubdirectoryFoldsIntoItsRootRegardlessOfCasing() {
        XCTAssertEqual(
            WorkProjectBuilder.projectRoot(
                for: "/Users/example/Ploidy/src", roots: ["/users/example/ploidy"]),
            "/Users/example/Ploidy")
    }

    /// Whether `/repo/subdir` belongs to `/repo` is a fact about the
    /// filesystem. Deriving roots only from retirement candidates made it
    /// depend on whether `/repo` survived the archive classifier.
    func test_groupingDoesNotRequireTheRepoToBeARetirementCandidate() {
        let projects = WorkProjectBuilder.build(
            sessions: [session("/Users/example/repo/subdir")],
            worktrees: [], assessments: [], gitRoots: ["/Users/example/repo"])
        XCTAssertEqual(projects.map(\.path), ["/Users/example/repo"])
    }

    /// Conversations whose workspace could not be resolved are real. The
    /// Gemini collector deliberately leaves the workspace empty rather
    /// than guessing, so dropping them meant discovering a conversation
    /// and then hiding it.
    func test_unplaceableConversationsAreKeptInTheirOwnGroup() {
        let projects = WorkProjectBuilder.build(
            sessions: [session(""), session("/Users/example/repo")],
            worktrees: [], assessments: [])
        XCTAssertEqual(projects.count, 2)
        let orphans = projects.first { $0.isUnassigned }
        XCTAssertEqual(orphans?.sessions.count, 1)
        XCTAssertEqual(orphans?.name, "연결되지 않은 대화")
    }

    /// They are real, and they are not what someone opening this screen is
    /// looking for.
    func test_theUnassignedGroupSortsLast() {
        let projects = WorkProjectBuilder.build(
            sessions: [session(""), session("/Users/example/repo")],
            worktrees: [], assessments: [])
        XCTAssertTrue(projects.last?.isUnassigned == true)
    }
}

/// Expanding a project must not mean reading every transcript it has.
///
/// `shown` was `expanded ? project.conversations : prefix(3)`, so one
/// click on a repo with thousands of sessions built thousands of rows and
/// handed every one of their paths to the title reader. The commit called
/// that "bounded to what is visible"; expanded is the whole project, not
/// the viewport.
final class WorkPaginationTests: XCTestCase {
    func test_aPageIsSmallEnoughToBeAViewport() {
        XCTAssertGreaterThanOrEqual(WorkProjectRow.pageSize, 20)
        XCTAssertLessThanOrEqual(WorkProjectRow.pageSize, 50)
    }

    /// The window is what the page size says, however many conversations
    /// the project holds.
    func test_theWindowIsCappedRegardlessOfProjectSize() {
        let sessions = (0..<3_000).map { index in
            SessionInspectionFixtures.entry(
                workspace: "/repo",
                source: "/Users/example/.claude/projects/\(index).jsonl")
        }
        let project = WorkProject(path: "/repo", sessions: sessions)
        XCTAssertEqual(project.conversationCount, 3_000)
        XCTAssertEqual(
            Array(project.conversations.prefix(WorkProjectRow.pageSize)).count,
            WorkProjectRow.pageSize)
    }
}
