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

/// What is known about a workspace's agent sessions at the moment an
/// archive is attempted.
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
    case bindings([SessionBinding])

    /// Sessions were found, copied into staging, and hashed.
    case sealed(ContinuityBundle)

    /// A human was shown that no assessment could be made and chose to
    /// archive anyway. Allowed, but the reason is written into the
    /// manifest so a later reader can tell this archive apart from one
    /// that was genuinely session-free.
    case overriddenByUser(reason: String)

    /// Sessions carried into the manifest, if any are sealed yet.
    public var sealedSessions: [SealedSession] {
        if case .sealed(let bundle) = self { return bundle.sessions }
        return []
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
        case .overriddenByUser: return "overridden-by-user"
        }
    }
}
