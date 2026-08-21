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

    /// Whether this repo may be retired at all.
    ///
    /// `.unsafe` means active work or unrecoverable-if-archived. Kept as a
    /// property of the assessment rather than as absence from a list, so
    /// a screen can show the repo and its state without implying it is a
    /// candidate.
    var isRetirementEligible: Bool { verdict.tier != .unsafe }

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
        case .bindings(let bindings, _):
            let bytes = ByteCountFormatter.string(
                fromByteCount: bindings.reduce(0) { $0 + $1.sizeBytes },
                countStyle: .file
            )
            return "연결된 AI 세션 \(bindings.count)개 · \(bytes)"
        case .sealed(let bundle, _):
            return "AI 세션 \(bundle.sessions.count)개 봉인됨"
        }
    }

    /// True while the repo still has conversations that only exist in the
    /// provider's own store — the state `ContinuityGate` refuses to
    /// archive from.
    /// Titles for the few sessions this row actually shows. Empty until
    /// they are fetched, and never consulted by the gate.
    var presentations: [SessionPresentation] = []

    /// The sessions themselves, so the row can offer to open one. Empty
    /// unless a binder has run and found some.
    var boundSessions: [SessionBinding] {
        if case .bindings(let bindings, _) = continuity { return bindings }
        return []
    }

    /// What the row shows on the right. The safety tier when nothing is
    /// bound, and the binding count when something is -- because that is
    /// the value that varies between rows and the one the decision turns
    /// on.
    var trailingLabel: String {
        boundSessions.isEmpty ? tierLabel : "대화 \(boundSessions.count)개"
    }

    /// The bindings worth putting a title on, most recently touched
    /// first.
    ///
    /// A retirement screen is a consequence view, not a browser: the
    /// question is "what would I lose", and a list of a hundred and
    /// twenty answers it worse than the few that carry most of the
    /// weight. Full exploration belongs on the AI 세션 screen.
    func topBindings(_ limit: Int = ArchiveCandidate.highlightLimit) -> [SessionBinding] {
        // By recency, not by size. The titles exist so someone recognises
        // the work they were in the middle of, and selecting on bytes
        // drops a small recent conversation for a large stale one before
        // the date sort downstream ever sees it.
        boundSessions
            .sorted { Self.lastActive($0) > Self.lastActive($1) }
            .prefix(limit)
            .map { $0 }
    }

    static func lastActive(_ binding: SessionBinding) -> Date {
        (try? binding.source.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    static let highlightLimit = 5

    var remainingSessionCount: Int {
        max(0, boundSessions.count - ArchiveCandidate.highlightLimit)
    }

    var hasUnsealedSessions: Bool {
        if case .bindings(let bindings, _) = continuity { return !bindings.isEmpty }
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

/// What `scree.py inspect` returns: one conversation, masked and capped
/// at the source, for a person to read.
///
/// Display-only by construction — nothing in the app routes this into a
/// verdict, and the Python side pins the same fact from its end (its
/// judgment outputs never carry these keys).
struct SessionConversation: Decodable, Equatable {
    struct Turn: Decodable, Equatable, Identifiable {
        /// The turn's ordinal in the window, supplied by `inspect`.
        ///
        /// Identity has to come from position, not content. Role plus
        /// text collides on exactly the case the dedupe rule
        /// deliberately preserves -- the same person saying the same
        /// thing twice with a reply in between -- and a `ForEach` given
        /// duplicate ids drops rows out of the conversation it was asked
        /// to show.
        let index: Int
        let role: String
        let text: String
        var id: Int { index }

        var isUser: Bool {
            ["user", "human", "user_message"].contains(role.lowercased())
        }
        var speakerLabel: String { isUser ? "나" : "에이전트" }
    }

    /// Whether the transcript could be read at all, and if not, why.
    ///
    /// `missing`, `unreadable` and `unrecognized` all yield zero turns,
    /// and rendering them as an empty conversation tells someone about to
    /// delete this repo that there was nothing to lose. Unknown strings
    /// decode to `.unrecognized` rather than failing the whole payload:
    /// a newer status is still a session this build could not show.
    enum Status: String, Decodable, Equatable {
        case ok
        case missing
        case unreadable
        case unrecognized

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unrecognized
        }

        /// What to put in front of the person, when there is nothing to show.
        var failureText: String? {
            switch self {
            case .ok: return nil
            case .missing: return "이 대화 파일은 더 이상 존재하지 않습니다. 제공자가 정리했을 수 있습니다."
            case .unreadable: return "이 대화 파일을 읽을 권한이 없습니다."
            case .unrecognized: return "이 대화 파일의 형식을 읽지 못했습니다."
            }
        }
    }

    /// Absent in payloads written before `inspect` reported status; those
    /// only ever came from a file it had just read, so `ok` is right.
    let status: Status
    let provider: String
    let sessionId: String
    let workspace: String?
    let messageCount: Int
    let userTurnCount: Int
    let firstUserTurn: String?
    let turns: [Turn]
    let omittedTurns: Int
    let masked: Bool

    private enum CodingKeys: String, CodingKey {
        case status, provider, sessionId, workspace, messageCount
        case userTurnCount, firstUserTurn, turns, omittedTurns, masked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .ok
        provider = try container.decode(String.self, forKey: .provider)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        userTurnCount = try container.decode(Int.self, forKey: .userTurnCount)
        firstUserTurn = try container.decodeIfPresent(String.self, forKey: .firstUserTurn)
        turns = try container.decode([Turn].self, forKey: .turns)
        omittedTurns = try container.decode(Int.self, forKey: .omittedTurns)
        masked = try container.decode(Bool.self, forKey: .masked)
    }
}

/// Where one conversation's fetch stands.
///
/// A fetch that fails has to leave something behind. Storing only the
/// success meant a failed `inspect` left the row spinning on "대화를
/// 읽는 중…" forever, which reads as a slow machine rather than as a
/// question that was answered and lost.
enum ConversationLoadState: Equatable {
    case loading
    case loaded(SessionConversation)
    case failed(String)

    var conversation: SessionConversation? {
        if case .loaded(let conversation) = self { return conversation }
        return nil
    }
}

/// Why one conversation could not be fetched, in words meant for the
/// person who asked to read it.
struct ScreeInspectionError: Error, Equatable {
    let message: String
}
