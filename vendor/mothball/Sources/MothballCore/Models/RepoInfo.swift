import Foundation

/// Snapshot of a git repository's state captured at scan time.
///
/// Missing activity evidence is distinct from an old activity timestamp.
/// Git metadata also has legitimate absences (no commits, detached HEAD,
/// or no configured remote).
public struct RepoInfo: Sendable, Hashable {
    public let path: URL
    public let sizeBytes: Int64

    /// Most recent file mtime anywhere in the working tree (including
    /// untracked files but excluding .git contents). Used as a fallback
    /// activity signal when there are no commits.
    public let lastFileMTime: Date?

    public let git: GitMetadata

    public init(path: URL, sizeBytes: Int64, lastFileMTime: Date?, git: GitMetadata) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastFileMTime = lastFileMTime
        self.git = git
    }

    public var activity: ActivityEvidence {
        guard let latest = [lastFileMTime, git.lastCommitDate].compactMap({ $0 }).max() else {
            return .noEvidence
        }
        return .observed(latest)
    }

    public var lastActivity: Date? { activity.observedAt }

}

public enum ActivityEvidence: Sendable, Hashable {
    case observed(Date)
    case noEvidence

    public var observedAt: Date? {
        if case .observed(let date) = self { return date }
        return nil
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
