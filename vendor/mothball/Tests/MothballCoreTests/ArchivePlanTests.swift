import XCTest
@testable import MothballCore

final class ArchivePlanTests: XCTestCase {

    func test_planProducesFourDistinctPaths() {
        let plan = makePlan()
        let urls = [plan.archiveTmp, plan.archiveFinal, plan.manifestTmp, plan.manifestFinal]
        XCTAssertEqual(Set(urls).count, 4)
    }

    func test_archivePathsLiveInArchiveDirectory() {
        let plan = makePlan(archiveDir: URL(fileURLWithPath: "/tmp/archive"))
        XCTAssertEqual(plan.archiveFinal.deletingLastPathComponent().path, "/tmp/archive")
        XCTAssertEqual(plan.manifestFinal.deletingLastPathComponent().path, "/tmp/archive")
    }

    func test_filenameContainsRepoNameAndTimestamp() {
        let plan = makePlan(
            repoName: "my-old-thing",
            archiveDir: URL(fileURLWithPath: "/tmp/archive")
        )
        XCTAssertTrue(plan.archiveFinal.lastPathComponent.hasPrefix("my-old-thing_"))
        XCTAssertTrue(plan.archiveFinal.lastPathComponent.hasSuffix(".tar.zst"))
        XCTAssertTrue(plan.manifestFinal.lastPathComponent.hasSuffix(".json"))
    }

    func test_tmpPathsMatchFinalPathsWithTmpSuffix() {
        let plan = makePlan()
        XCTAssertEqual(plan.archiveTmp.path, plan.archiveFinal.path + ".tmp")
        XCTAssertEqual(plan.manifestTmp.path, plan.manifestFinal.path + ".tmp")
    }

    func test_filenameIsFilesystemSafe_noColons() {
        let plan = makePlan()
        // ISO 8601 includes `:` in time, which is illegal on some
        // filesystems and confusing in shells. We must replace them.
        XCTAssertFalse(plan.archiveFinal.lastPathComponent.contains(":"))
        XCTAssertFalse(plan.manifestFinal.lastPathComponent.contains(":"))
    }

    // MARK: -

    private func makePlan(
        repoName: String = "repo",
        archiveDir: URL = URL(fileURLWithPath: "/tmp/archive"),
        date: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> ArchivePlan {
        let repoURL = URL(fileURLWithPath: "/Users/x/IdeaProjects/\(repoName)")
        let repo = RepoInfo(
            path: repoURL,
            sizeBytes: 1_000_000,
            lastFileMTime: date,
            git: GitMetadata(
                lastCommitDate: date,
                isDirty: false,
                aheadOfOrigin: 0,
                originURL: "https://github.com/me/\(repoName).git",
                currentBranch: "main",
                headSHA: "abc"
            )
        )
        return ArchivePlan(repo: repo, archiveDirectory: archiveDir, now: date)
    }
}
