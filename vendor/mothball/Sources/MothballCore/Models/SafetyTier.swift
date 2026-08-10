import Foundation

public enum SafetyTier: Sendable, Hashable {
    /// Recommended for archiving. All recovery information is on origin.
    case safe

    /// Archivable but with caveats. Some recovery information exists
    /// only locally and will be preserved inside the archive.
    case caution

    /// Must not be archived. Either active work or unrecoverable.
    case unsafe
}

/// One specific reason contributing to a tier classification.
/// Surfaced in the UI tooltip so users can see *why* a repo was
/// classified this way.
public enum SafetyReason: Sendable, Hashable {
    case recentActivity(daysAgo: Int)
    case dirtyWorkingTree
    case unpushedCommits(count: Int)
    case noRemoteConfigured
    case noUpstreamConfigured
    case noCommitsYet
    case dormant(daysAgo: Int)
    case fullyPushed
}

public struct SafetyVerdict: Sendable, Hashable {
    public let tier: SafetyTier
    public let reasons: [SafetyReason]

    public init(tier: SafetyTier, reasons: [SafetyReason]) {
        self.tier = tier
        self.reasons = reasons
    }
}
