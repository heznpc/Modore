import Foundation

/// The staged, hashed session capsule for one workspace.
///
/// `stagingRoot` holds copies, not the originals. Hashing the original
/// and compressing it later would leave a window in which the agent
/// appends to its own transcript between the two steps, and the manifest
/// would then describe bytes the archive does not contain.
public struct ContinuityBundle: Sendable, Equatable {
    /// Directory whose *contents* become the session archive. Owned by
    /// the sealer; the orchestrator only reads it.
    public let stagingRoot: URL
    public let sessions: [SealedSession]

    public init(stagingRoot: URL, sessions: [SealedSession]) {
        self.stagingRoot = stagingRoot
        self.sessions = sessions
    }

    public var totalBytes: Int64 { sessions.reduce(0) { $0 + $1.sizeBytes } }
    public var fileCount: Int { sessions.reduce(0) { $0 + $1.fileCount } }
}

/// How much of the machine's session stores a binder actually read.
///
/// Carried alongside the bindings, not only used to qualify an empty
/// result. "Found a session" and "found every session" are different
/// facts, and a model that keeps the difference only when the list is
/// empty loses it exactly where it costs most: a shallow pass that turns
/// up one Codex session says nothing about the Claude session that ran
/// from a parent directory, or about a store no binder reads at all.
public enum BindingCoverage: String, Codable, Sendable, Hashable {
    /// Matched recorded working directories only.
    case shallow
    /// Read transcript bodies and stopped early, or skipped a store.
    case truncated
    /// Every bindable store read to the end, and no store left unread.
    case complete

    public init(reported: String?) {
        self = BindingCoverage(rawValue: reported ?? "") ?? .shallow
    }

    public var label: String {
        switch self {
        case .shallow: return "일부만 확인"
        case .truncated: return "검사 중단됨"
        case .complete: return "전부 확인"
        }
    }
}

/// What is known about a workspace's agent sessions at the moment an
/// archive is attempted.
///
/// There is deliberately no "the user decided to proceed anyway" case.
/// One existed while Mothball shipped standalone with no binder, and
/// nothing ever constructed it: it sat in the enum passing the gate and
/// serialising to a manifest tag no manifest could carry. A case that
/// always allows and nobody creates is not an escape hatch, it is an
/// unguarded one -- the next person adding an override reaches for it
/// and inherits the permission without building the confirmation that
/// would justify it. If an override is wanted, it arrives with the UI
/// that asks.
///
/// The distinction that makes this type worth existing is `notAssessed`
/// versus `assessedNoSessions`. Collapsing both into "no sessions" — an
/// empty array, a nil, a zero count — is the bug this whole gate exists
/// to prevent: a caller that never ran the binder becomes indistinguishable
/// from one that ran it and found nothing, and the workspace is deleted
/// with its conversation history still only referenced by a path that is
/// about to stop existing.
public enum ContinuityAssessment: Sendable {
    /// No binder has run. Fail closed.
    case notAssessed

    /// A binder ran to completion and found no sessions for this
    /// workspace. Safe to archive: there is nothing to lose.
    case assessedNoSessions

    /// Sessions were found but their bytes are not yet in the archive.
    /// Blocked — archiving here would trash the workspace while the
    /// transcripts stay behind in the provider's own store, where the
    /// provider's retention sweep will eventually delete them.
    case bindings([SessionBinding], coverage: BindingCoverage)

    /// Sessions were found, copied into staging, and hashed. The coverage
    /// travels with them: sealing the sessions a partial scan happened to
    /// find preserves those and silently abandons the ones it never
    /// looked for, which is a worse outcome than refusing, because it
    /// looks like success.
    case sealed(ContinuityBundle, coverage: BindingCoverage)

    /// Sessions carried into the manifest, if any are sealed yet.
    public var sealedSessions: [SealedSession] {
        if case .sealed(let bundle, _) = self { return bundle.sessions }
        return []
    }

    /// How much of the store the answer rests on. `assessedNoSessions` is
    /// only reachable from a complete pass, and the two states that
    /// predate any scan have no coverage to report.
    public var coverage: BindingCoverage? {
        switch self {
        case .notAssessed: return nil
        case .assessedNoSessions: return .complete
        case .bindings(_, let coverage), .sealed(_, let coverage): return coverage
        }
    }

    /// Stable tag recorded in the manifest. Spelled out rather than
    /// derived from the case name so renaming a case cannot silently
    /// change the on-disk format.
    public var manifestTag: String {
        switch self {
        case .notAssessed: return "not-assessed"
        case .assessedNoSessions: return "assessed-no-sessions"
        case .bindings: return "bindings-unsealed"
        case .sealed: return "sealed"
        }
    }
}
