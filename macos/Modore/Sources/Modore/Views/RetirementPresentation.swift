import SwiftUI
import MothballCore

/// How retirement facts are worded for a person.
///
/// What is left of the old `레포 은퇴` page. The page itself is gone --
/// retirement is an action on a project now, raised from the 작업 screen
/// as a sheet -- but these are pure functions over value types that say
/// how a binding, a session and a candidate list should read, and the
/// rules they encode were learned the hard way. `RetirementReviewSheet`
/// and the work list are their callers now.
enum RetirementPresentation {
    nonisolated static func subtitle(_ session: SessionPresentation) -> String {
        var parts = ["\(session.provider.displayName) \(session.kindLabel)"]
        if let last = session.lastActiveAt {
            parts.append(Self.dayFormatter.string(from: last))
        }
        parts.append(ByteCountFormatter.string(fromByteCount: session.sizeBytes, countStyle: .file))
        if session.titleSource.isWeak {
            parts.append("제목 추정")
        }
        return parts.joined(separator: " · ")
    }

    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M월 d일"
        return f
    }()

    /// What the whole list amounts to, stated once at the top.
    ///
    /// `nonisolated`, like the other formatters below it. These are pure
    /// functions over value types; they live on the view only because
    /// that is where they are read from, and inheriting its main-actor
    /// isolation made them untestable from anywhere else.
    ///
    /// Every row here already carries a tier label, and on a machine that
    /// uses agents heavily every row reads the same -- so the label sorts
    /// nothing and the reader has to scan 53 identical lines to learn the
    /// only fact that varies. This says it up front instead.
    nonisolated static func boundSummary(_ candidates: [ArchiveCandidate]) -> String {
        // "None" and "not checked yet" are the distinction this whole
        // feature exists to keep, and the summary was collapsing it: while
        // the binder ran, every row correctly read "확인 안 됨" and the
        // line above them announced that nothing was connected.
        let unassessed = candidates.filter { $0.continuity.coverage == nil }
        let withSessions = candidates.filter { !$0.boundSessions.isEmpty }
        guard !withSessions.isEmpty else {
            return unassessed.isEmpty
                ? "연결된 AI 대화가 있는 저장소는 없습니다."
                : "AI 대화 연결을 확인하는 중입니다. 아직 아무것도 확정하지 않았습니다."
        }
        // Deduplicate across candidates. A repo and its own worktrees are
        // separate rows, and binding matches by path prefix, so every
        // worktree conversation is bound to both -- measured here, five of
        // AirMCP's sessions appear under two candidates. Summing the rows
        // would tell the user they are about to lose more than exists.
        var seen: Set<String> = []
        var bytes: Int64 = 0
        for candidate in withSessions {
            for binding in candidate.boundSessions {
                let key = "\(binding.provider.rawValue)/\(binding.sessionID)"
                guard seen.insert(key).inserted else { continue }
                bytes += binding.sizeBytes
            }
        }
        let sessions = seen.count
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(withSessions.count)개 저장소에 AI 대화 \(sessions)개(\(size))가 묶여 있습니다. 지우면 함께 끊깁니다."
    }

    /// Long enough to browse, short enough that a 120-session repo does
    /// not turn one row into a page.
    nonisolated static let boundSessionDisplayLimit = 20

    nonisolated static func evidenceText(_ binding: SessionBinding) -> String {
        let evidence = binding.evidence.map { evidenceLabel($0) }.joined(separator: " · ")
        let size = ByteCountFormatter.string(fromByteCount: binding.sizeBytes, countStyle: .file)
        return "\(evidence) · \(confidenceLabel(binding.confidence)) · \(size)"
    }

    nonisolated private static func evidenceLabel(_ evidence: BindingEvidence) -> String {
        switch evidence {
        case .remoteURL: return "원격 URL 기록됨"
        case .workingDirectory: return "작업 디렉터리 일치"
        case .fileAccess: return "파일 접근 기록"
        }
    }

    nonisolated private static func confidenceLabel(_ confidence: BindingConfidence) -> String {
        switch confidence {
        case .high: return "확실"
        case .medium: return "보통"
        case .low: return "약함"
        }
    }
}
