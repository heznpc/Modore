import Foundation

/// Snapshot of a git repository's state captured at scan time.
///
/// All fields are nullable where git can legitimately have no answer
/// (empty repo with no commits, detached HEAD, no remote configured).
/// Callers must not interpret nil as "unknown" — it means the property
/// genuinely does not exist for this repo.
public struct RepoInfo: Sendable, Hashable {
    public let path: URL
    public let sizeBytes: Int64

    /// Most recent file mtime anywhere in the working tree (including
    /// untracked files but excluding .git contents). Used as a fallback
    /// activity signal when there are no commits.
    public let lastFileMTime: Date

    public let git: GitMetadata

    public init(path: URL, sizeBytes: Int64, lastFileMTime: Date, git: GitMetadata) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastFileMTime = lastFileMTime
        self.git = git
    }

    /// The most recent activity signal from any source. Used by the
    /// classifier as the primary "is this dormant?" signal.
    public var lastActivity: Date {
        if let commit = git.lastCommitDate {
            return max(commit, lastFileMTime)
        }
        return lastFileMTime
    }
}

public struct GitMetadata: Sendable, Hashable {
    /// nil when the repo has no commits at all (freshly `git init`ed).
    public let lastCommitDate: Date?

    /// True if `git status --porcelain` produces any output.
    public let isDirty: Bool

    /// Commits on local branch not yet pushed to its upstream.
    /// nil when there is no upstream tracking branch configured.
    public let aheadOfOrigin: Int?

    /// Value of `remote.origin.url`, or nil if no `origin` remote exists.
    public let originURL: String?

    /// Current branch name, or nil if HEAD is detached.
    public let currentBranch: String?

    /// Resolved HEAD commit SHA, or nil if no commits.
    public let headSHA: String?

    public init(
        lastCommitDate: Date?,
        isDirty: Bool,
        aheadOfOrigin: Int?,
        originURL: String?,
        currentBranch: String?,
        headSHA: String?
    ) {
        self.lastCommitDate = lastCommitDate
        self.isDirty = isDirty
        self.aheadOfOrigin = aheadOfOrigin
        self.originURL = originURL
        self.currentBranch = currentBranch
        self.headSHA = headSHA
    }

    public var hasRemote: Bool { originURL != nil }
    public var hasUpstream: Bool { aheadOfOrigin != nil }
    public var isFullyPushed: Bool { (aheadOfOrigin ?? 0) == 0 }
}
