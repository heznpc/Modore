import Foundation

/// Decides whether a workspace may be archived given what is known about
/// its agent sessions.
///
/// Separate from `SafetyClassifier` on purpose. The classifier answers a
/// git question — is this work pushed, is it dormant — and grades the
/// answer into tiers a human reads. This gate answers a different
/// question with a different shape: it is binary, it is not advisory, and
/// it is not something the caller can talk its way past by showing the
/// user a warning. A `.caution` tier still lands in the candidate list;
/// a gate refusal stops the archive.
public enum ContinuityGate {

    public enum Refusal: Sendable, Equatable {
        /// No binder ran. The workspace may or may not have sessions and
        /// nobody looked.
        case notAssessed

        /// Sessions exist and are still only in the provider's store.
        case unsealedSessions(count: Int)
    }

    public enum Verdict: Sendable, Equatable {
        case allow
        case block(Refusal)

        public var isAllowed: Bool { if case .allow = self { return true }; return false }
    }

    /// Pure and total: every assessment maps to exactly one verdict, and
    /// the mapping is the whole policy. Kept free of I/O so the policy
    /// can be tested without a filesystem.
    public static func evaluate(_ assessment: ContinuityAssessment) -> Verdict {
        switch assessment {
        case .notAssessed:
            return .block(.notAssessed)
        case .bindings(let bindings):
            // An empty `bindings([])` is a caller bug, not a pass: the
            // binder that produced it should have returned
            // `.assessedNoSessions`. Refusing keeps the one distinction
            // this type exists to preserve from leaking away through a
            // degenerate array.
            return .block(.unsealedSessions(count: bindings.count))
        case .assessedNoSessions, .sealed, .overriddenByUser:
            return .allow
        }
    }
}

extension ContinuityGate.Refusal {
    /// User-facing explanation. Phrased as what to do next, because every
    /// refusal here is recoverable by running one more step.
    public var message: String {
        switch self {
        case .notAssessed:
            return "AI 세션 연결을 확인하지 않았습니다. 세션 감사를 먼저 실행하세요."
        case .unsealedSessions(let count):
            return "이 저장소에 연결된 AI 세션 \(count)개가 아직 봉인되지 않았습니다. 봉인 후 다시 시도하세요."
        }
    }
}
