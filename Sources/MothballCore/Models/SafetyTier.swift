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

    public var humanDescription: String {
        switch self {
        case .recentActivity(let d):
            return "마지막 활동 \(d)일 전 (30일 미만)"
        case .dirtyWorkingTree:
            return "커밋되지 않은 변경 사항 있음"
        case .unpushedCommits(let n):
            return "origin에 push되지 않은 커밋 \(n)개"
        case .noRemoteConfigured:
            return "origin remote 설정 없음 (복원 불가)"
        case .noUpstreamConfigured:
            return "현재 브랜치에 upstream 추적 없음"
        case .noCommitsYet:
            return "커밋이 하나도 없는 빈 저장소"
        case .dormant(let d):
            return "휴면 상태 (\(d)일 전 마지막 활동)"
        case .fullyPushed:
            return "origin에 모두 push됨"
        }
    }
}

public struct SafetyVerdict: Sendable, Hashable {
    public let tier: SafetyTier
    public let reasons: [SafetyReason]

    public init(tier: SafetyTier, reasons: [SafetyReason]) {
        self.tier = tier
        self.reasons = reasons
    }
}
