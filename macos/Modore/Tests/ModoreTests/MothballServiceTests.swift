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
        let text = candidate(continuity: .bindings(bindings, coverage: .complete)).continuityText
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
            ], coverage: .complete)).verdict.tier
        )
    }

    func test_unsealedSessionsAreFlaggedForTheRow() {
        XCTAssertFalse(candidate(continuity: .assessedNoSessions).hasUnsealedSessions)
        XCTAssertFalse(candidate(continuity: .notAssessed).hasUnsealedSessions)
        XCTAssertTrue(candidate(continuity: .bindings([
            SessionBinding(provider: .codex, sessionID: "c",
                           source: URL(fileURLWithPath: "/s/c.jsonl"),
                           evidence: [.remoteURL], confidence: .high)
        ], coverage: .complete)).hasUnsealedSessions)
    }
}

/// The per-session line the expanded row shows. A count says a delete
/// costs something; this says what and how firmly it is attached.
final class BoundSessionRowTests: XCTestCase {

    private func binding(
        provider: SessionProvider = .claude,
        evidence: [BindingEvidence] = [.workingDirectory],
        confidence: BindingConfidence = .medium,
        sizeBytes: Int64 = 2_000_000
    ) -> SessionBinding {
        SessionBinding(
            provider: provider, sessionID: "3a4f0f71",
            source: URL(fileURLWithPath: "/s/3a4f0f71.jsonl"),
            evidence: evidence, confidence: confidence, sizeBytes: sizeBytes
        )
    }

    func test_evidenceTextNamesTheEvidenceConfidenceAndSize() {
        let text = MothballCandidateSection.evidenceText(binding())
        XCTAssertTrue(text.contains("작업 디렉터리"), text)
        XCTAssertTrue(text.contains("보통"), text)
        XCTAssertTrue(text.contains("MB"), text)
    }

    /// Codex records the remote URL itself, and that is a stronger claim
    /// than a path match — the row has to say which one it is.
    func test_remoteURLEvidenceReadsDifferentlyFromAPathMatch() {
        let recorded = MothballCandidateSection.evidenceText(
            binding(provider: .codex, evidence: [.remoteURL], confidence: .high)
        )
        let inferred = MothballCandidateSection.evidenceText(binding())
        XCTAssertNotEqual(recorded, inferred)
        XCTAssertTrue(recorded.contains("원격 URL"), recorded)
        XCTAssertTrue(recorded.contains("확실"), recorded)
    }

    func test_allEvidenceTypesAreLabelled() {
        let text = MothballCandidateSection.evidenceText(
            binding(evidence: [.remoteURL, .workingDirectory, .fileAccess])
        )
        for fragment in ["원격 URL", "작업 디렉터리", "파일 접근"] {
            XCTAssertTrue(text.contains(fragment), "\(fragment) missing from \(text)")
        }
    }

    /// A truncated list that ends silently reads as a complete one, and a
    /// repo with 120 bound sessions would otherwise look like it had 20.
    func test_displayLimitIsBoundedSoOneRowCannotBecomeAPage() {
        XCTAssertGreaterThan(MothballCandidateSection.boundSessionDisplayLimit, 0)
        XCTAssertLessThanOrEqual(MothballCandidateSection.boundSessionDisplayLimit, 50)
    }
}

/// The page's job is to keep a delete from quietly stranding
/// conversations, so what it sorts by and what it puts in the row's most
/// readable slot both have to follow that, not repo size.
final class CandidateOrderingTests: XCTestCase {
    private let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(sizeBytes: Int64, sessions: Int, idPrefix: String = "s") -> ArchiveCandidate {
        let activity = referenceNow.addingTimeInterval(-400 * 86_400)
        let repo = RepoInfo(
            path: URL(fileURLWithPath: "/tmp/r\(sizeBytes)"), sizeBytes: sizeBytes,
            lastFileMTime: activity,
            git: GitMetadata(lastCommitDate: activity, isDirty: false, aheadOfOrigin: 0,
                             originURL: "git@example.com:t/r.git", currentBranch: "main",
                             headSHA: "abc")
        )
        var c = ArchiveCandidate(
            repo: repo, verdict: SafetyClassifier().classify(repo, now: referenceNow),
            dormancyDays: 400
        )
        if sessions > 0 {
            c.continuity = .bindings((0..<sessions).map { i in
                SessionBinding(provider: .claude, sessionID: "\(idPrefix)\(i)",
                               source: URL(fileURLWithPath: "/s/\(i).jsonl"),
                               evidence: [.workingDirectory], confidence: .medium,
                               sizeBytes: 1_000)
            }, coverage: .complete)
        } else {
            c.continuity = .assessedNoSessions
        }
        return c
    }

    /// The largest repo is not the riskiest one to delete.
    func test_moreStrandedConversationsSortsAboveALargerRepo() {
        let big = candidate(sizeBytes: 10_000_000_000, sessions: 4)
        let small = candidate(sizeBytes: 1_000, sessions: 120)
        let ordered = [big, small].sorted {
            if $0.boundSessions.count != $1.boundSessions.count {
                return $0.boundSessions.count > $1.boundSessions.count
            }
            return $0.repo.sizeBytes > $1.repo.sizeBytes
        }
        XCTAssertEqual(ordered.first?.boundSessions.count, 120)
    }

    /// Fifty-three rows reading "주의 필요" sort nothing. The slot goes to
    /// the value that differs.
    func test_trailingLabelCarriesTheVaryingValue() {
        XCTAssertEqual(candidate(sizeBytes: 1, sessions: 7).trailingLabel, "대화 7개")
        XCTAssertNotEqual(
            candidate(sizeBytes: 1, sessions: 7).trailingLabel,
            candidate(sizeBytes: 1, sessions: 120).trailingLabel
        )
    }

    /// With nothing bound there is no count to show, so the tier is still
    /// the most useful thing available.
    func test_trailingLabelFallsBackToTheTierWhenNothingIsBound() {
        let none = candidate(sizeBytes: 1, sessions: 0)
        XCTAssertEqual(none.trailingLabel, none.tierLabel)
    }

    func test_summaryStatesTheTotalAtRiskRatherThanWhereTheFeatureIsNot() {
        let summary = MothballCandidateSection.boundSummary([
            candidate(sizeBytes: 1, sessions: 3, idPrefix: "a"),
            candidate(sizeBytes: 2, sessions: 5, idPrefix: "b"),
            candidate(sizeBytes: 3, sessions: 0),
        ])
        XCTAssertTrue(summary.contains("2개 저장소"), summary)
        XCTAssertTrue(summary.contains("8개"), summary)
    }

    /// A repo and its own worktrees are separate rows, and binding matches
    /// by path prefix, so every worktree conversation is bound to both.
    /// Measured on this machine, five of AirMCP's sessions appear under two
    /// candidates. Summing the rows would tell the user they are about to
    /// lose more than exists.
    func test_summaryCountsASessionBoundToTwoCandidatesOnce() {
        let shared = MothballCandidateSection.boundSummary([
            candidate(sizeBytes: 1, sessions: 5, idPrefix: "same"),
            candidate(sizeBytes: 2, sessions: 5, idPrefix: "same"),
        ])
        XCTAssertTrue(shared.contains("5개"), shared)
        XCTAssertFalse(shared.contains("10개"), shared)
    }

    func test_summarySaysSoWhenNothingIsAtRisk() {
        let summary = MothballCandidateSection.boundSummary([candidate(sizeBytes: 1, sessions: 0)])
        XCTAssertTrue(summary.contains("없습니다"), summary)
    }
}

/// The row a person reads. The old one showed a UUID, an evidence type,
/// and a byte count -- storage identity. What someone remembers is the
/// work, so that is what the row leads with; the forensic detail stays
/// available and stops being the headline.
final class SessionPresentationTests: XCTestCase {

    private func session(
        title: String = "결제 오류 재현 및 수정",
        source: TitleSource = .firstRequest,
        provider: SessionProvider = .claude,
        daysAgo: Int = 1
    ) -> SessionPresentation {
        SessionPresentation(
            provider: provider, sessionID: "abc123",
            title: title, titleSource: source,
            lastActiveAt: Date(timeIntervalSince1970: 1_800_000_000)
                .addingTimeInterval(-Double(daysAgo) * 86_400),
            sizeBytes: 2_000_000
        )
    }

    /// A quoted request and a date-shaped label look alike in a list and
    /// mean very different things. Showing a guess with the confidence of
    /// a quotation is how someone decides against a conversation they
    /// never actually saw.
    func test_inferredTitlesAreMarkedAndQuotedOnesAreNot() {
        XCTAssertTrue(MothballCandidateSection.subtitle(session(source: .date)).contains("추정"))
        XCTAssertTrue(MothballCandidateSection.subtitle(session(source: .recentTurn)).contains("추정"))
        XCTAssertFalse(MothballCandidateSection.subtitle(session(source: .firstRequest)).contains("추정"))
    }

    /// Every continued session opens with a resumption marker, so a title
    /// taken from one is a guess about the subject, not a quote of it.
    func test_resumptionTitlesCountAsWeak() {
        XCTAssertTrue(TitleSource.resumption.isWeak)
        XCTAssertFalse(TitleSource.firstRequest.isWeak)
    }

    /// "세 개의 대화"와 "세 개의 편집기 창이 이 폴더를 기억함"은 다른 경고다.
    func test_editorStateIsNotLabelledAsAConversation() {
        XCTAssertEqual(session(provider: .claude).kindLabel, "대화")
        XCTAssertEqual(session(provider: .vscode).kindLabel, "편집기 상태")
        XCTAssertTrue(MothballCandidateSection.subtitle(session(provider: .kiro)).contains("편집기"))
    }

    /// A consequence view, not a browser: a hundred and twenty rows
    /// answer "what would I lose" worse than the few that carry the
    /// weight -- and the ones left out have to be named.
    func test_highlightsAreBoundedAndTheRemainderIsCounted() throws {
        let repo = RepoInfo(
            path: URL(fileURLWithPath: "/tmp/x"), sizeBytes: 1,
            lastFileMTime: Date(timeIntervalSince1970: 0),
            git: GitMetadata(lastCommitDate: nil, isDirty: false, aheadOfOrigin: 0,
                             originURL: nil, currentBranch: nil, headSHA: nil)
        )
        var candidate = ArchiveCandidate(
            repo: repo, verdict: SafetyClassifier().classify(repo), dormancyDays: 400
        )
        // Real files with real timestamps: selection reads mtime, and a
        // fixture of nonexistent paths would silently fall back to the
        // original order and prove nothing.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "Highlights-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        candidate.continuity = .bindings(try (0..<120).map { i in
            let file = dir.appending(path: "\(i).jsonl")
            try Data("{}\n".utf8).write(to: file)
            // Older as the index grows, and *larger* as it grows too --
            // so a size-based selection would pick the opposite five.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 - Double(i) * 60)],
                ofItemAtPath: file.path
            )
            return SessionBinding(provider: .claude, sessionID: "s\(i)", source: file,
                                  evidence: [.workingDirectory], confidence: .medium,
                                  sizeBytes: Int64(i))
        }, coverage: .complete)

        XCTAssertEqual(candidate.topBindings().count, ArchiveCandidate.highlightLimit)
        XCTAssertEqual(candidate.remainingSessionCount, 120 - ArchiveCandidate.highlightLimit)
        // The five most recently touched. Titles exist so someone
        // recognises the work they were in the middle of, and selecting
        // on bytes drops a small recent conversation for a large stale
        // one before any later date sort can see it.
        XCTAssertEqual(candidate.topBindings().map(\.sessionID), ["s0", "s1", "s2", "s3", "s4"])
    }

    /// The cache has to notice a transcript rewritten to the same length,
    /// which is what a compaction produces -- mtime and size alone do not.
    func test_cacheKeyIncludesFileIdentity() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "PresentationKey-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appending(path: "a.jsonl")
        let b = dir.appending(path: "b.jsonl")
        try Data("same-size".utf8).write(to: a)
        try Data("same-size".utf8).write(to: b)

        let keyA = PresentationCacheKey(provider: .claude, sessionID: "s", source: a)
        let keyB = PresentationCacheKey(provider: .claude, sessionID: "s", source: b)
        XCTAssertNotNil(keyA)
        XCTAssertNotEqual(keyA, keyB, "identical size and near-identical mtime must not collide")
    }

    func test_cacheKeyIsNilForAMissingSource() {
        XCTAssertNil(PresentationCacheKey(
            provider: .claude, sessionID: "s",
            source: URL(fileURLWithPath: "/nope/\(UUID().uuidString).jsonl")
        ))
    }
}
