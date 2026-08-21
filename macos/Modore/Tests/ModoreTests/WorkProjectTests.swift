import XCTest
import MothballCore
@testable import Modore

/// The roll-up is the whole point of merging the two screens. An agent
/// worktree records its own directory as the workspace, so a repo with
/// twenty agent runs produced twenty unrelated-looking entries -- the
/// low-level artifact view that made the old screens hard to read.
final class WorkProjectRollupTests: XCTestCase {
    private let repo = "/Users/example/IdeaProjects/ploidy"

    private func session(_ workspace: String, tool: String = "Claude",
                         lastActive: String = "2026-08-20 10:00") -> SessionIndexEntry {
        SessionInspectionFixtures.entry(
            tool: tool, workspace: workspace,
            source: "/Users/example/.claude/projects/\(UUID().uuidString).jsonl",
            lastActive: lastActive)
    }

    func test_agentWorktreesFoldIntoTheirRepo() {
        let projects = WorkProjectBuilder.build(
            sessions: [
                session(repo),
                session("\(repo)/.claude/worktrees/affectionate-cohen-f52bc6"),
                session("\(repo)/.claude/worktrees/eager-noether-01ab"),
            ],
            worktrees: [], assessments: [])

        XCTAssertEqual(projects.count, 1,
                       "three agent runs in one repo are one project, not three")
        XCTAssertEqual(projects.first?.path, repo)
        XCTAssertEqual(projects.first?.sessions.count, 3)
    }

    /// The fold must not need a git scan to have happened first, or the
    /// list opens as a pile of adjectives and surnames.
    func test_theFoldDoesNotWaitForAScanner() {
        let root = WorkProjectBuilder.projectRoot(
            for: "\(repo)/.claude/worktrees/affectionate-cohen-f52bc6", roots: [])
        XCTAssertEqual(root, repo)
    }

    /// A subdirectory belongs to the project that contains it, and the
    /// longest known root wins so a nested project keeps its own identity.
    func test_theLongestKnownRootWins() {
        let outer = "/Users/example/IdeaProjects/Paper"
        let inner = "\(outer)/ai-slop-paper"
        XCTAssertEqual(
            WorkProjectBuilder.projectRoot(for: "\(inner)/experiments/amsm",
                                           roots: [outer, inner]),
            inner)
    }

    func test_anUnknownWorkspaceStaysItsOwnProject() {
        XCTAssertEqual(
            WorkProjectBuilder.projectRoot(for: "/Users/example/scratch", roots: [repo]),
            "/Users/example/scratch")
    }

    func test_aTrailingSlashIsNotADifferentProject() {
        XCTAssertEqual(
            WorkProjectBuilder.projectRoot(for: repo + "/", roots: [repo]), repo)
    }

    /// A prefix match must respect path boundaries: `/foo-bar` is not
    /// inside `/foo`.
    func test_aSiblingWithASharedPrefixIsNotSwallowed() {
        XCTAssertEqual(
            WorkProjectBuilder.projectRoot(for: "\(repo)-archive", roots: [repo]),
            "\(repo)-archive")
    }

    /// Was: dropped entirely. A conversation whose workspace could not be
    /// resolved still exists, and hiding it after finding it is the
    /// opposite of what this app is for.
    func test_sessionsWithoutAWorkspaceAreKeptAsUnassigned() {
        let projects = WorkProjectBuilder.build(
            sessions: [session("")], worktrees: [], assessments: [])
        XCTAssertEqual(projects.count, 1)
        XCTAssertTrue(projects[0].isUnassigned)
    }

    func test_projectsAreOrderedByMostRecentWork() {
        let projects = WorkProjectBuilder.build(
            sessions: [
                session("/Users/example/old", lastActive: "2026-01-01 10:00"),
                session("/Users/example/new", lastActive: "2026-08-21 10:00"),
            ], worktrees: [], assessments: [])
        XCTAssertEqual(projects.map(\.name), ["new", "old"])
    }

    func test_sessionsInsideAProjectAreNewestFirst() {
        let projects = WorkProjectBuilder.build(
            sessions: [
                session(repo, lastActive: "2026-01-01 10:00"),
                session(repo, lastActive: "2026-08-21 10:00"),
            ], worktrees: [], assessments: [])
        XCTAssertEqual(projects.first?.sessions.first?.lastActive, "2026-08-21 10:00")
    }

    /// Editor state counts toward what a project holds, but not toward
    /// the conversations you can open.
    func test_editorStateIsHeldButNotCountedAsAConversation() {
        let projects = WorkProjectBuilder.build(
            sessions: [
                session(repo, tool: "Claude"),
                SessionInspectionFixtures.entry(tool: "VS Code", workspace: repo),
            ], worktrees: [], assessments: [])
        XCTAssertEqual(projects.first?.sessions.count, 2)
        XCTAssertEqual(projects.first?.conversationCount, 1)
    }

    func test_toolsAreListedWithoutRepeats() {
        let projects = WorkProjectBuilder.build(
            sessions: [session(repo, tool: "Claude"),
                       session(repo, tool: "Claude"),
                       session(repo, tool: "Codex")],
            worktrees: [], assessments: [])
        XCTAssertEqual(projects.first?.tools.sorted(), ["Claude", "Codex"])
    }
}
