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

    /// What a binder found out about this repo's AI sessions, or
    /// `.notAssessed` when none has run yet.
    ///
    /// Deliberately not folded into `verdict`. `SafetyClassifier` answers
    /// a git question and grades it into tiers a human reads; this is a
    /// different question with a different shape, and the tier a repo
    /// gets must not change depending on whether a binder happened to
    /// have finished. A repo with forty bound conversations and one with
    /// none are the same `.safe` — what differs is what the row says next
    /// to it, and whether `ContinuityGate` lets an archive proceed.
    var continuity: ContinuityAssessment = .notAssessed

    /// Why `continuity` is `.notAssessed`, when the reason is that the
    /// binder could not run rather than that it has not been asked to.
    ///
    /// Without this the two look identical in the UI, and a broken binder
    /// presents as "every repo is unassessed" — which is true, and
    /// useless, and hides that the tool itself is what needs fixing.
    var continuityDiagnostic: String?

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

    /// The line the user reads before deciding. Phrased so the
    /// unassessed state is visible rather than looking like a clean bill
    /// of health — "확인 안 됨" and "없음" have to be different sentences,
    /// for the same reason they are different cases in the model.
    var continuityText: String {
        switch continuity {
        case .notAssessed:
            return continuityDiagnostic.map { "AI 세션 확인 실패 · \($0)" } ?? "AI 세션 확인 안 됨"
        case .assessedNoSessions:
            return "연결된 AI 세션 없음"
        case .bindings(let bindings):
            let bytes = ByteCountFormatter.string(
                fromByteCount: bindings.reduce(0) { $0 + $1.sizeBytes },
                countStyle: .file
            )
            return "연결된 AI 세션 \(bindings.count)개 · \(bytes)"
        case .sealed(let bundle):
            return "AI 세션 \(bundle.sessions.count)개 봉인됨"
        case .overriddenByUser:
            return "AI 세션 확인 없이 진행함"
        }
    }

    /// True while the repo still has conversations that only exist in the
    /// provider's own store — the state `ContinuityGate` refuses to
    /// archive from.
    /// The sessions themselves, so the row can offer to open one. Empty
    /// unless a binder has run and found some.
    var boundSessions: [SessionBinding] {
        if case .bindings(let bindings) = continuity { return bindings }
        return []
    }

    /// What the row shows on the right. The safety tier when nothing is
    /// bound, and the binding count when something is -- because that is
    /// the value that varies between rows and the one the decision turns
    /// on.
    var trailingLabel: String {
        boundSessions.isEmpty ? tierLabel : "대화 \(boundSessions.count)개"
    }

    var hasUnsealedSessions: Bool {
        if case .bindings(let bindings) = continuity { return !bindings.isEmpty }
        return false
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
