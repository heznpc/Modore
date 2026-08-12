import Foundation
import MothballCore

/// A dormant git repo, found among the workspace paths scree already
/// discovered, judged by MothballCore's own read-only git inspection. This
/// is display data only -- no case here archives or deletes anything; see
/// MothballPage's own header comment for why.
struct ArchiveCandidate: Identifiable {
    var id: String { repo.path.path }
    let repo: RepoInfo
    let verdict: SafetyVerdict
    /// Computed once, alongside `verdict`, from the same `now` reference --
    /// never re-derived at render time, so the displayed day count can
    /// never drift from the tier it was judged against.
    let dormancyDays: Int

    var pathText: String { repo.path.path }
    var pathLastComponent: String { repo.path.lastPathComponent }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: repo.sizeBytes, countStyle: .file)
    }

    var tierLabel: String {
        switch verdict.tier {
        case .safe: return "보관 추천"
        case .caution: return "주의 필요"
        case .unsafe: return "보관 불가"
        }
    }

    var tierSymbolName: String {
        switch verdict.tier {
        case .safe: return "archivebox"
        case .caution: return "exclamationmark.triangle"
        case .unsafe: return "lock.fill"
        }
    }

    var reasonText: String {
        verdict.reasons.map(Self.describe).joined(separator: " · ")
    }

    private static func describe(_ reason: SafetyReason) -> String {
        switch reason {
        case .recentActivity(let daysAgo): return "최근 활동 \(daysAgo)일 전"
        case .dirtyWorkingTree: return "커밋 안 된 변경 있음"
        case .unpushedCommits(let count): return "미푸시 커밋 \(count)개"
        case .noRemoteConfigured: return "원격 저장소 없음"
        case .noUpstreamConfigured: return "업스트림 미설정"
        case .noCommitsYet: return "커밋 없음"
        case .dormant(let daysAgo): return "\(daysAgo)일간 미사용"
        case .fullyPushed: return "원격에 모두 반영됨"
        }
    }
}
