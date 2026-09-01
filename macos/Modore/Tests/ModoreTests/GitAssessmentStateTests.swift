import XCTest
import MothballCore
@testable import Modore

/// `nil` used to mean three different things about a repo's git state:
/// judged and clean, never reached because the scan stopped at its root
/// cap, and reached but unreadable. All three drew the same row.
final class GitAssessmentStateTests: XCTestCase {
    private func lineage(_ path: String, hasGit: Bool = true) -> ScreeLineagePath {
        ScreeLineagePath(json: ["path": path, "exists": true, "has_git": hasGit])
    }

    // MARK: - the cap is disclosed rather than applied silently

    func test_theRootCapReportsWhatItLeftOut() {
        let paths = (0..<12).map { lineage("/Users/example/repo\($0)") }
        let scope = MothballService.scanScope(from: paths, limit: 10)
        XCTAssertEqual(scope.roots.count, 10)
        XCTAssertEqual(scope.notScanned, ["/Users/example/repo10", "/Users/example/repo11"])
    }

    func test_nonGitPathsAreNotReportedAsUnscannedRepos() {
        let scope = MothballService.scanScope(
            from: [lineage("/Users/example/a"), lineage("/Users/example/b", hasGit: false)],
            limit: 1)
        XCTAssertEqual(scope.roots.count, 1)
        XCTAssertTrue(scope.notScanned.isEmpty, "a plain directory is not an unscanned repo")
    }

    func test_candidateRootsStillReturnsOnlyTheRootsItAlwaysDid() {
        let paths = (0..<5).map { lineage("/Users/example/repo\($0)") }
        XCTAssertEqual(
            MothballService.candidateRoots(from: paths, limit: 3).map(\.path),
            MothballService.scanScope(from: paths, limit: 3).roots.map(\.path))
    }

    func test_unknownPathProbeIsNotScheduledAsARepositoryScan() {
        let unknown = ScreeLineagePath(json: [
            "path": "/Volumes/offline/repo",
            "exists": NSNull(),
            "has_git": NSNull(),
        ])

        let scope = MothballService.scanScope(from: [unknown])

        XCTAssertTrue(scope.roots.isEmpty)
        XCTAssertTrue(scope.notScanned.isEmpty)
    }

    // MARK: - the three states reach the project

    private func project(
        failures: [String: String] = [:], notScanned: [String] = [],
        assessments: [ArchiveCandidate] = []
    ) -> WorkProject {
        WorkProjectBuilder.build(
            sessions: [SessionInspectionFixtures.entry(workspace: "/Users/example/repo")],
            worktrees: [], assessments: assessments,
            gitRoots: ["/Users/example/repo"],
            scanFailures: failures, notScanned: notScanned
        )[0]
    }

    func test_aRepoTheScanNeverReachedSaysSo() {
        let p = project(notScanned: ["/Users/example/repo"])
        XCTAssertEqual(p.git, .notScanned)
        XCTAssertNil(p.assessment)
        XCTAssertNotNil(p.git.unknownReason)
        XCTAssertTrue(p.git.unknownReason!.contains("검사 범위 밖"))
    }

    func test_aRepoTheScanCouldNotReadSaysSomethingElse() {
        let p = project(failures: ["/Users/example/repo": "permission denied"])
        XCTAssertEqual(p.git, .failed("permission denied"))
        XCTAssertNotNil(p.git.unknownReason)
        XCTAssertNotEqual(p.git.unknownReason, GitAssessmentState.notScanned.unknownReason,
                          "not reached and not readable call for different actions")
    }

    /// A project that never claimed to be a repository has no git answer
    /// to withhold, so it must not carry an "unknown" line either.
    func test_aProjectThatIsNotARepoClaimsNothing() {
        let p = WorkProjectBuilder.build(
            sessions: [SessionInspectionFixtures.entry(workspace: "/Users/example/scratch")],
            worktrees: [], assessments: [])[0]
        XCTAssertEqual(p.git, .notApplicable)
        XCTAssertNil(p.git.unknownReason)
    }

    /// A repo that was judged is judged, whatever else the scan reported.
    func test_anAssessmentWinsOverAFailureForTheSamePath() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repo = RepoInfo(
            path: URL(fileURLWithPath: "/Users/example/repo"), sizeBytes: 1,
            lastFileMTime: now.addingTimeInterval(-400 * 86_400),
            git: GitMetadata(lastCommitDate: now.addingTimeInterval(-400 * 86_400),
                             isDirty: false, aheadOfOrigin: 0,
                             originURL: "git@example.com:a/b.git",
                             currentBranch: "main", headSHA: "abc"))
        let assessed = MothballService.assessRepos(repos: [repo], now: now)
        let p = project(failures: ["/Users/example/repo": "timed out"], assessments: assessed)
        XCTAssertNotNil(p.assessment)
        XCTAssertNil(p.git.unknownReason)
    }
}

/// Binding reads every session store per pass. Spending that on repos
/// that can never be archived -- the `.unsafe` ones, unsafe precisely
/// because they hold live work -- answers a question nobody asked.
final class ContinuityScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func repo(_ path: String, origin: String?) -> RepoInfo {
        let activity = now.addingTimeInterval(-400 * 86_400)
        return RepoInfo(
            path: URL(fileURLWithPath: path), sizeBytes: 1, lastFileMTime: activity,
            git: GitMetadata(lastCommitDate: activity, isDirty: false, aheadOfOrigin: 0,
                             originURL: origin, currentBranch: "main", headSHA: "abc"))
    }

    func test_onlyRetirableReposAreWorthBinding() {
        let assessments = MothballService.assessRepos(
            repos: [repo("/Users/example/clean", origin: "git@example.com:a/b.git"),
                    repo("/Users/example/noremote", origin: nil)],
            now: now)
        XCTAssertEqual(assessments.count, 2, "both are still assessed")
        XCTAssertEqual(assessments.filter(\.isRetirementEligible).count, 1,
                       "only one of them has a retirement to review")
    }
}

/// Facts that describe a repo without warning about it were computed and
/// then dropped on the floor: "400일 미사용" -- the very reason a repo is
/// a good retirement candidate -- never reached the screen.
final class GitNotesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func assessed(dirty: Bool, daysIdle: Double) -> WorkProject {
        let activity = now.addingTimeInterval(-daysIdle * 86_400)
        let repo = RepoInfo(
            path: URL(fileURLWithPath: "/Users/example/repo"), sizeBytes: 1,
            lastFileMTime: activity,
            git: GitMetadata(lastCommitDate: activity, isDirty: dirty, aheadOfOrigin: 0,
                             originURL: "git@example.com:a/b.git",
                             currentBranch: "main", headSHA: "abc"))
        return WorkProject(
            path: "/Users/example/repo",
            git: .assessed(MothballService.assessRepos(repos: [repo], now: now)[0]))
    }

    func test_dormancyIsCarriedAsANoteNotAsARisk() {
        let p = assessed(dirty: false, daysIdle: 400)
        XCTAssertTrue(p.gitRisks.isEmpty)
        XCTAssertTrue(p.gitNotes.contains { $0.contains("400") },
                      "the reason it is a good candidate must reach the row")
        XCTAssertFalse(p.needsAttention)
    }

    func test_risksAndNotesAreDisjoint() {
        let p = assessed(dirty: true, daysIdle: 400)
        XCTAssertFalse(p.gitRisks.isEmpty)
        XCTAssertFalse(p.gitNotes.isEmpty)
        XCTAssertTrue(Set(p.gitRisks).isDisjoint(with: Set(p.gitNotes)))
    }

    func test_anUnassessedProjectOffersNeither() {
        let p = WorkProject(path: "/Users/example/repo", git: .notScanned)
        XCTAssertTrue(p.gitRisks.isEmpty)
        XCTAssertTrue(p.gitNotes.isEmpty)
    }
}

/// The retirement sheet holds an id, not a snapshot. Continuity binding
/// finishes after the sheet can already be open, and a captured value
/// would keep showing the counts from before the binder ran -- on the one
/// screen whose whole job is to say what a retirement would strand.
final class RetirementReviewTargetTests: XCTestCase {
    func test_theTargetIsIdentityOnly() {
        let target = RetirementReviewTarget(id: "/Users/example/repo")
        XCTAssertEqual(target.id, "/Users/example/repo")
    }

    /// The id a target carries is the id a rebuilt project list resolves
    /// to, including after the assessment attached to it changes.
    func test_aTargetStillResolvesAfterTheProjectIsRebuilt() {
        let sessions = [SessionInspectionFixtures.entry(workspace: "/Users/example/Repo")]
        let before = WorkProjectBuilder.build(
            sessions: sessions, worktrees: [], assessments: [])[0]
        let target = RetirementReviewTarget(id: before.id)

        let after = WorkProjectBuilder.build(
            sessions: sessions, worktrees: [], assessments: [],
            gitRoots: ["/Users/example/repo"], notScanned: ["/Users/example/repo"])
        XCTAssertNotNil(after.first { $0.id == target.id },
                        "casing and rebuilt state must not lose the sheet's target")
    }
}
