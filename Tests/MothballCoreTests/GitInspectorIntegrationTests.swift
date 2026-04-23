import XCTest
@testable import MothballCore

/// Integration tests that drive a real git binary against a real
/// temporary repository. Skipped automatically on hosts without git
/// at /usr/bin/git (e.g. CI containers without it preinstalled).
final class GitInspectorIntegrationTests: XCTestCase {
    var repo: TempGitRepo!
    let inspector = GitInspector()

    override func setUp() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "git not available at /usr/bin/git"
        )
        repo = try TempGitRepo()
    }

    override func tearDown() async throws {
        repo?.cleanup()
        repo = nil
    }

    // MARK: -

    func test_freshlyInitedRepo_hasNoCommitsAndNoRemote() async throws {
        try await repo.initialize()

        let meta = try await inspector.inspect(repoAt: repo.url)

        XCTAssertNil(meta.lastCommitDate, "no commits yet")
        XCTAssertNil(meta.headSHA)
        XCTAssertNil(meta.originURL)
        XCTAssertNil(meta.aheadOfOrigin)
        XCTAssertFalse(meta.isDirty, "empty working tree is clean")
    }

    func test_repoWithOneCommit_returnsCommitDateAndHead() async throws {
        try await repo.initialize()
        try repo.writeFile("README.md")
        try await repo.commit("initial")

        let meta = try await inspector.inspect(repoAt: repo.url)

        XCTAssertNotNil(meta.lastCommitDate)
        XCTAssertNotNil(meta.headSHA)
        XCTAssertEqual(meta.currentBranch, "main")
        XCTAssertFalse(meta.isDirty)
    }

    func test_uncommittedChange_marksRepoDirty() async throws {
        try await repo.initialize()
        try repo.writeFile("README.md")
        try await repo.commit("initial")
        try repo.writeFile("untracked.txt")

        let meta = try await inspector.inspect(repoAt: repo.url)

        XCTAssertTrue(meta.isDirty)
    }

    func test_repoWithFakeUpstream_reportsZeroAhead() async throws {
        try await repo.initialize()
        try repo.writeFile("README.md")
        try await repo.commit("initial")
        try await repo.fakePushedOrigin()

        let meta = try await inspector.inspect(repoAt: repo.url)

        XCTAssertEqual(meta.originURL, "git@example.invalid:fake/repo.git")
        XCTAssertEqual(meta.aheadOfOrigin, 0)
        XCTAssertTrue(meta.git.isFullyPushed)
    }

    func test_unpushedCommitsAreCounted() async throws {
        try await repo.initialize()
        try repo.writeFile("README.md")
        try await repo.commit("initial")
        try await repo.fakePushedOrigin()

        try repo.writeFile("two.txt")
        try await repo.commit("second")
        try repo.writeFile("three.txt")
        try await repo.commit("third")

        let meta = try await inspector.inspect(repoAt: repo.url)

        XCTAssertEqual(meta.aheadOfOrigin, 2)
    }

    func test_detachedHead_branchIsNil() async throws {
        try await repo.initialize()
        try repo.writeFile("README.md")
        try await repo.commit("initial")

        let head = try await repo.git(["rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await repo.git(["checkout", "-q", head])

        let meta = try await inspector.inspect(repoAt: repo.url)

        XCTAssertNil(meta.currentBranch, "detached HEAD has no branch name")
        XCTAssertNotNil(meta.headSHA)
    }

    func test_throwsForNonRepoDirectory() async throws {
        let notARepo = repo.url.appending(path: "not-a-repo")
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)

        do {
            _ = try await inspector.inspect(repoAt: notARepo)
            XCTFail("expected GitInspector.Error.notARepository")
        } catch GitInspector.Error.notARepository {
            // expected
        }
    }
}
