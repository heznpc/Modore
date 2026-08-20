import Foundation

/// Which agent wrote a session transcript. The two providers differ in a
/// way that matters to the binder: Codex records the repository URL in
/// its own session header, Claude records only a working directory, so
/// a Claude binding always costs a content scan while a Codex binding is
/// free.
public enum SessionProvider: String, Codable, Sendable, Hashable, CaseIterable {
    case claude
    case codex
    case gemini
    case vscode
    case kiro
    case cursor
    case windsurf
    case antigravity

    /// Editors keep per-workspace state -- open tabs, an AI panel's
    /// history, local settings -- rather than a transcript. Worth
    /// preserving and worth labelling differently, because "three
    /// conversations" and "three editor windows remembered this folder"
    /// are not the same warning.
    public var keepsTranscripts: Bool {
        switch self {
        case .claude, .codex, .gemini: return true
        case .vscode, .kiro, .cursor, .windsurf, .antigravity: return false
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .vscode: return "VS Code"
        case .kiro: return "Kiro"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .antigravity: return "Antigravity"
        }
    }
}

/// Why a session is believed to belong to a repository.
///
/// Kept as a list rather than a single value because the evidence is
/// cumulative — a session that both ran in the repo directory *and*
/// named its remote is bound more firmly than one that only did either.
public enum BindingEvidence: String, Codable, Sendable, Hashable {
    /// The session store recorded the repo's remote URL itself. The only
    /// evidence that survives the workspace being moved or deleted.
    case remoteURL = "remote-url"

    /// The session's recorded working directory was the repo path.
    case workingDirectory = "working-directory"

    /// Paths under the repo appear in the transcript's tool activity.
    /// The weakest signal on its own: reading a file proves a visit, not
    /// ownership.
    case fileAccess = "file-access"
}

/// How much the binding can be trusted. Drives whether a human is asked
/// to confirm before the workspace is retired, so the levels are
/// deliberately coarse — a numeric score would invite a threshold nobody
/// can justify.
public enum BindingConfidence: String, Codable, Sendable, Hashable {
    /// The provider itself recorded the repository identity.
    case high
    /// Inferred from the working directory alone.
    case medium
    /// Inferred only from file access, or from a path that no longer
    /// exists and could not be re-checked against git.
    case low
}

/// One session found to belong to a repository, before sealing.
///
/// `source` is a live path on the sealing machine and is deliberately
/// *not* what ends up in the manifest: it is invalid on any other
/// machine and the provider's own retention sweep can delete it. Sealing
/// turns this into a `SealedSession` whose bytes live inside the archive.
public struct SessionBinding: Sendable, Hashable {
    public let provider: SessionProvider
    public let sessionID: String

    /// The top-level transcript file as it exists right now.
    public let source: URL

    /// Per-session subagent/workflow transcripts, which live in a
    /// directory beside the top-level file. Separated from `source`
    /// because the provider's cleanup deletes the parent transcript and
    /// leaves these behind — a bundle that copied only `source` would
    /// silently drop the bulk of the record.
    public let subtranscripts: [URL]

    public let evidence: [BindingEvidence]
    public let confidence: BindingConfidence

    /// Uncompressed size of the transcript plus its subagent tree, as the
    /// binder measured it. Carried this far so the user sees what sealing
    /// will cost *before* agreeing to it — on this machine one repo's
    /// sessions come to 624 MB, which is not a number to discover
    /// afterwards.
    public let sizeBytes: Int64

    public init(
        provider: SessionProvider,
        sessionID: String,
        source: URL,
        subtranscripts: [URL] = [],
        evidence: [BindingEvidence],
        confidence: BindingConfidence,
        sizeBytes: Int64 = 0
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.source = source
        self.subtranscripts = subtranscripts
        self.evidence = evidence
        self.confidence = confidence
        self.sizeBytes = sizeBytes
    }
}

/// One session after its bytes have been copied into staging and hashed.
///
/// `artifact` is a path *inside the session archive*, never an absolute
/// path. The hash describes the staged copy, not the original: the
/// original can still change after this record is written, the copy
/// cannot.
public struct SealedSession: Codable, Sendable, Hashable {
    public let provider: SessionProvider
    public let sessionID: String
    public let artifact: String
    public let sha256: String
    public let sizeBytes: Int64
    public let fileCount: Int
    public let evidence: [BindingEvidence]
    public let confidence: BindingConfidence

    public init(
        provider: SessionProvider,
        sessionID: String,
        artifact: String,
        sha256: String,
        sizeBytes: Int64,
        fileCount: Int,
        evidence: [BindingEvidence],
        confidence: BindingConfidence
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.artifact = artifact
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.evidence = evidence
        self.confidence = confidence
    }
}
