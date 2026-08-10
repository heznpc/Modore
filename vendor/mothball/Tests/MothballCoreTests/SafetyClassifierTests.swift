import XCTest
@testable import MothballCore

final class SafetyClassifierTests: XCTestCase {
    let classifier = SafetyClassifier()
    let now = Date(timeIntervalSince1970: 1_750_000_000)  // arbitrary fixed point

    // MARK: - Test helpers

    private func repo(
        daysAgo: Int,
        isDirty: Bool = false,
        hasRemote: Bool = true,
        hasUpstream: Bool = true,
        ahead: Int = 0,
        hasCommits: Bool = true
    ) -> RepoInfo {
        let activity = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return RepoInfo(
            path: URL(fileURLWithPath: "/tmp/r"),
            sizeBytes: 1_000_000,
            lastFileMTime: activity,
            git: GitMetadata(
                lastCommitDate: hasCommits ? activity : nil,
                isDirty: isDirty,
                aheadOfOrigin: hasUpstream ? ahead : nil,
                originURL: hasRemote ? "https://github.com/me/r.git" : nil,
                currentBranch: "main",
                headSHA: hasCommits ? "abc123" : nil
            )
        )
    }

    // MARK: - Recent activity dominates

    func test_recentActivity_isAlwaysUnsafe() {
        let v = classifier.classify(repo(daysAgo: 5), now: now)
        XCTAssertEqual(v.tier, .unsafe)
        XCTAssertEqual(v.reasons, [.recentActivity(daysAgo: 5)])
    }

    func test_recentActivity_overridesOtherwiseSafeRepo() {
        // Even a clean, fully-pushed repo is unsafe if recently touched.
        let v = classifier.classify(repo(daysAgo: 0), now: now)
        XCTAssertEqual(v.tier, .unsafe)
    }

    func test_recentActivity_overridesNoRemote() {
        // Recent-activity check fires before we even look at remote state.
        let v = classifier.classify(
            repo(daysAgo: 10, hasRemote: false, hasUpstream: false),
            now: now
        )
        XCTAssertEqual(v.tier, .unsafe)
        XCTAssertEqual(v.reasons.count, 1)  // only recentActivity
    }

    // MARK: - No remote means unsafe

    func test_dormantWithoutRemote_isUnsafe() {
        let v = classifier.classify(
            repo(daysAgo: 365, hasRemote: false, hasUpstream: false),
            now: now
        )
        XCTAssertEqual(v.tier, .unsafe)
        XCTAssertTrue(v.reasons.contains(.noRemoteConfigured))
    }

    // MARK: - Caution range (30-180 days)

    func test_partiallyDormantClean_isCaution() {
        let v = classifier.classify(repo(daysAgo: 90), now: now)
        XCTAssertEqual(v.tier, .caution)
        XCTAssertTrue(v.reasons.contains(.dormant(daysAgo: 90)))
        XCTAssertTrue(v.reasons.contains(.fullyPushed))
    }

    func test_partiallyDormantDirty_isCaution() {
        let v = classifier.classify(repo(daysAgo: 90, isDirty: true), now: now)
        XCTAssertEqual(v.tier, .caution)
        XCTAssertTrue(v.reasons.contains(.dirtyWorkingTree))
        XCTAssertFalse(v.reasons.contains(.fullyPushed))
    }

    // MARK: - Safe (fully dormant + clean + pushed)

    func test_fullyDormantClean_isSafe() {
        let v = classifier.classify(repo(daysAgo: 365), now: now)
        XCTAssertEqual(v.tier, .safe)
        XCTAssertTrue(v.reasons.contains(.fullyPushed))
    }

    func test_fullyDormantWithUnpushed_isCaution() {
        let v = classifier.classify(repo(daysAgo: 365, ahead: 3), now: now)
        XCTAssertEqual(v.tier, .caution)
        XCTAssertTrue(v.reasons.contains(.unpushedCommits(count: 3)))
    }

    func test_fullyDormantWithoutUpstream_isCaution() {
        let v = classifier.classify(repo(daysAgo: 365, hasUpstream: false), now: now)
        XCTAssertEqual(v.tier, .caution)
        XCTAssertTrue(v.reasons.contains(.noUpstreamConfigured))
    }

    func test_fullyDormantWithMultipleProblems_collectsAllReasons() {
        let v = classifier.classify(
            repo(daysAgo: 365, isDirty: true, ahead: 5),
            now: now
        )
        XCTAssertEqual(v.tier, .caution)
        XCTAssertTrue(v.reasons.contains(.dirtyWorkingTree))
        XCTAssertTrue(v.reasons.contains(.unpushedCommits(count: 5)))
    }

    // MARK: - Threshold boundaries

    func test_exactlyAtRecentActivityThreshold_isCaution() {
        // 30 days exactly: leaves the recent-activity zone, enters caution.
        let v = classifier.classify(repo(daysAgo: 30), now: now)
        XCTAssertEqual(v.tier, .caution)
    }

    func test_oneDayBeforeThreshold_isUnsafe() {
        let v = classifier.classify(repo(daysAgo: 29), now: now)
        XCTAssertEqual(v.tier, .unsafe)
    }

    func test_exactlyAtDormantThreshold_isSafe() {
        let v = classifier.classify(repo(daysAgo: 180), now: now)
        XCTAssertEqual(v.tier, .safe)
    }

    func test_oneDayBeforeDormantThreshold_isCaution() {
        let v = classifier.classify(repo(daysAgo: 179), now: now)
        XCTAssertEqual(v.tier, .caution)
    }

    // MARK: - Empty repo edge case

    func test_emptyRepoUsesFileMTime() {
        // No commits, but file mtime is old → falls through to dormant logic.
        let v = classifier.classify(
            repo(daysAgo: 365, hasUpstream: false, hasCommits: false),
            now: now
        )
        // No commits implies hasUpstream is false (we wired it that way),
        // so this is caution — not safe — because of noUpstreamConfigured.
        XCTAssertEqual(v.tier, .caution)
    }

    // MARK: - Custom thresholds

    func test_customThresholdsAreRespected() {
        let aggressive = SafetyClassifier(thresholds: .init(
            recentActivityDays: 7,
            dormantDays: 60
        ))
        // 90 days dormant under aggressive thresholds → safe.
        let v = aggressive.classify(repo(daysAgo: 90), now: now)
        XCTAssertEqual(v.tier, .safe)
    }
}
