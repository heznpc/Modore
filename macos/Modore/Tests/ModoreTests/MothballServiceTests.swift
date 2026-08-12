import XCTest
@testable import Modore
@testable import MothballCore

final class MothballServiceTests: XCTestCase {
    // Fixed instant rather than Date() -- SafetyClassifier.classify's own
    // doc comment calls out `now` as "injectable for deterministic tests";
    // this test suite follows the same discipline for rankCandidates.
    private let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func repoInfo(
        path: String,
        daysAgo: Int,
        isDirty: Bool = false,
        aheadOfOrigin: Int? = 0,
        originURL: String? = "git@example.com:test/repo.git",
        sizeBytes: Int64 = 1_024
    ) -> RepoInfo {
        let activity = referenceNow.addingTimeInterval(-Double(daysAgo) * 86_400)
        return RepoInfo(
            path: URL(fileURLWithPath: path),
            sizeBytes: sizeBytes,
            lastFileMTime: activity,
            git: GitMetadata(
                lastCommitDate: activity,
                isDirty: isDirty,
                aheadOfOrigin: aheadOfOrigin,
                originURL: originURL,
                currentBranch: "main",
                headSHA: "abc123"
            )
        )
    }

    // MARK: - candidateRoots

    func testCandidateRootsIncludesOnlyExistingGitRepos() {
        let paths = [
            ScreeLineagePath(json: ["path": "/Users/test/repo-a", "exists": true, "has_git": true]),
            ScreeLineagePath(json: ["path": "/Users/test/plain-folder", "exists": true, "has_git": false]),
            ScreeLineagePath(json: ["path": "/Users/test/vanished-repo", "exists": false, "has_git": true]),
        ]

        let roots = MothballService.candidateRoots(from: paths)

        XCTAssertEqual(roots, [URL(fileURLWithPath: "/Users/test/repo-a")])
    }

    func testCandidateRootsRespectsLimit() {
        let paths = (0..<10).map {
            ScreeLineagePath(json: ["path": "/Users/test/repo-\($0)", "exists": true, "has_git": true])
        }

        let roots = MothballService.candidateRoots(from: paths, limit: 3)

        XCTAssertEqual(roots.count, 3)
    }

    // MARK: - rankCandidates

    func testRankCandidatesExcludesUnsafeTier() {
        let recentlyTouched = repoInfo(path: "/Users/test/active", daysAgo: 1)

        let candidates = MothballService.rankCandidates(repos: [recentlyTouched], now: referenceNow)

        XCTAssertTrue(candidates.isEmpty)
    }

    func testRankCandidatesIncludesSafeAndCautionTiers() {
        let safe = repoInfo(path: "/Users/test/safe", daysAgo: 200)
        let caution = repoInfo(path: "/Users/test/caution", daysAgo: 200, isDirty: true)

        let candidates = MothballService.rankCandidates(repos: [safe, caution], now: referenceNow)

        XCTAssertEqual(Set(candidates.map { $0.pathLastComponent }), ["safe", "caution"])
        let safeCandidate = try? XCTUnwrap(candidates.first { $0.pathLastComponent == "safe" })
        XCTAssertEqual(safeCandidate?.verdict.tier, .safe)
        let cautionCandidate = try? XCTUnwrap(candidates.first { $0.pathLastComponent == "caution" })
        XCTAssertEqual(cautionCandidate?.verdict.tier, .caution)
    }

    func testRankCandidatesSortsBySizeDescending() {
        let small = repoInfo(path: "/Users/test/small", daysAgo: 200, sizeBytes: 100)
        let large = repoInfo(path: "/Users/test/large", daysAgo: 200, sizeBytes: 900)

        let candidates = MothballService.rankCandidates(repos: [small, large], now: referenceNow)

        XCTAssertEqual(candidates.map { $0.pathLastComponent }, ["large", "small"])
    }

    func testRankCandidatesComputesDormancyDaysOnceFromTheSameNow() {
        let safe = repoInfo(path: "/Users/test/safe", daysAgo: 200)

        let candidates = MothballService.rankCandidates(repos: [safe], now: referenceNow)

        XCTAssertEqual(candidates.first?.dormancyDays, 200)
    }
}
