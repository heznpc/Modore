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

/// The row a user reads before deciding, and the reason this whole path
/// exists: two repos with identical git state must not look identical
/// when one has forty bound conversations and the other has none.
final class ArchiveCandidateContinuityTests: XCTestCase {
    private let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(continuity: ContinuityAssessment) -> ArchiveCandidate {
        let activity = referenceNow.addingTimeInterval(-400 * 86_400)
        let repo = RepoInfo(
            path: URL(fileURLWithPath: "/tmp/example"),
            sizeBytes: 1_024,
            lastFileMTime: activity,
            git: GitMetadata(
                lastCommitDate: activity, isDirty: false, aheadOfOrigin: 0,
                originURL: "git@example.com:test/repo.git", currentBranch: "main",
                headSHA: "abc"
            )
        )
        var c = ArchiveCandidate(
            repo: repo,
            verdict: SafetyClassifier().classify(repo, now: referenceNow),
            dormancyDays: 400
        )
        c.continuity = continuity
        return c
    }

    /// A fresh candidate has not been bound yet, and must say so rather
    /// than defaulting to the reassuring answer.
    func test_defaultIsNotAssessed() {
        let activity = referenceNow.addingTimeInterval(-400 * 86_400)
        let repo = RepoInfo(
            path: URL(fileURLWithPath: "/tmp/example"), sizeBytes: 1,
            lastFileMTime: activity,
            git: GitMetadata(lastCommitDate: activity, isDirty: false, aheadOfOrigin: 0,
                             originURL: nil, currentBranch: nil, headSHA: nil)
        )
        let fresh = ArchiveCandidate(
            repo: repo, verdict: SafetyClassifier().classify(repo, now: referenceNow),
            dormancyDays: 400
        )
        guard case .notAssessed = fresh.continuity else {
            return XCTFail("an unbound candidate must not default to looking session-free")
        }
    }

    func test_unassessedAndSessionFreeReadDifferently() {
        let unknown = candidate(continuity: .notAssessed).continuityText
        let none = candidate(continuity: .assessedNoSessions).continuityText
        XCTAssertNotEqual(unknown, none,
                          "\"확인 안 됨\"과 \"없음\"은 같은 문장이 될 수 없다")
        XCTAssertTrue(unknown.contains("확인"))
    }

    func test_boundSessionsShowCountAndSize() {
        let bindings = (0..<3).map { i in
            SessionBinding(
                provider: .claude, sessionID: "s\(i)",
                source: URL(fileURLWithPath: "/s/\(i).jsonl"),
                evidence: [.workingDirectory], confidence: .medium,
                sizeBytes: 1_000_000
            )
        }
        let text = candidate(continuity: .bindings(bindings)).continuityText
        XCTAssertTrue(text.contains("3개"), text)
        XCTAssertTrue(text.contains("MB"), "봉인 비용을 결정 전에 보여줘야 한다: \(text)")
    }

    /// The git tier is unchanged by sessions on purpose — the gate, not
    /// the classifier, is what stops the archive.
    func test_sessionsDoNotChangeTheGitTier() {
        XCTAssertEqual(
            candidate(continuity: .notAssessed).verdict.tier,
            candidate(continuity: .bindings([
                SessionBinding(provider: .codex, sessionID: "c",
                               source: URL(fileURLWithPath: "/s/c.jsonl"),
                               evidence: [.remoteURL], confidence: .high)
            ])).verdict.tier
        )
    }

    func test_unsealedSessionsAreFlaggedForTheRow() {
        XCTAssertFalse(candidate(continuity: .assessedNoSessions).hasUnsealedSessions)
        XCTAssertFalse(candidate(continuity: .notAssessed).hasUnsealedSessions)
        XCTAssertTrue(candidate(continuity: .bindings([
            SessionBinding(provider: .codex, sessionID: "c",
                           source: URL(fileURLWithPath: "/s/c.jsonl"),
                           evidence: [.remoteURL], confidence: .high)
        ])).hasUnsealedSessions)
    }
}
