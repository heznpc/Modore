import Foundation

public struct SafetyClassifier: Sendable {
    public struct Thresholds: Sendable, Equatable {
        /// Activity within this window keeps a repo classified `.unsafe`
        /// regardless of git state — assume the user is still working on it.
        public let recentActivityDays: Int

        /// Dormancy for at least this long is required for `.safe`.
        /// Between `recentActivityDays` and this, repos are at best `.caution`.
        public let dormantDays: Int

        public static let `default` = Thresholds(
            recentActivityDays: 30,
            dormantDays: 180
        )

        public init(recentActivityDays: Int, dormantDays: Int) {
            precondition(recentActivityDays < dormantDays,
                         "recentActivityDays must be less than dormantDays")
            self.recentActivityDays = recentActivityDays
            self.dormantDays = dormantDays
        }
    }

    public let thresholds: Thresholds

    public init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    /// `now` is injectable for deterministic tests.
    public func classify(_ repo: RepoInfo, now: Date = Date()) -> SafetyVerdict {
        let dormancyDays = daysBetween(repo.lastActivity, now)

        // Recent activity: unconditionally unsafe. Don't archive things
        // the user is currently using.
        if dormancyDays < thresholds.recentActivityDays {
            return SafetyVerdict(
                tier: .unsafe,
                reasons: [.recentActivity(daysAgo: dormancyDays)]
            )
        }

        var reasons: [SafetyReason] = [.dormant(daysAgo: dormancyDays)]

        // No remote means the only copy of the work is local.
        // Compressing-then-deleting is recoverable from the archive,
        // but the user has *no* origin to clone from later. Refuse.
        guard repo.git.hasRemote else {
            return SafetyVerdict(
                tier: .unsafe,
                reasons: reasons + [.noRemoteConfigured]
            )
        }

        // From here we know: dormant >= recentActivityDays AND has remote.
        // Grade by what work is local-only.
        var localOnlyProblems: [SafetyReason] = []

        if repo.git.isDirty {
            localOnlyProblems.append(.dirtyWorkingTree)
        }

        if !repo.git.hasUpstream {
            // Has an `origin` remote but the current branch has no
            // upstream tracking — we can't prove things are pushed.
            localOnlyProblems.append(.noUpstreamConfigured)
        } else if let ahead = repo.git.aheadOfOrigin, ahead > 0 {
            localOnlyProblems.append(.unpushedCommits(count: ahead))
        }

        if localOnlyProblems.isEmpty {
            reasons.append(.fullyPushed)
        } else {
            reasons.append(contentsOf: localOnlyProblems)
        }

        // Decision: safe requires both deep dormancy AND nothing local-only.
        // Anything else is caution — archivable but with caveats.
        let isFullyDormant = dormancyDays >= thresholds.dormantDays
        let tier: SafetyTier = (isFullyDormant && localOnlyProblems.isEmpty)
            ? .safe
            : .caution
        return SafetyVerdict(tier: tier, reasons: reasons)
    }

    private func daysBetween(_ earlier: Date, _ later: Date) -> Int {
        let interval = later.timeIntervalSince(earlier)
        return max(0, Int(interval / 86_400))
    }
}
