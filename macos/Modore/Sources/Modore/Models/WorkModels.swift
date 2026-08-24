import Foundation
import MothballCore

/// One title for one session, as `scree.py titles` returns it.
struct SessionTitle: Decodable, Equatable {
    let title: String?
    let titleSource: String

    /// A guessed label shown with the same confidence as a real request is
    /// how a person decides against a conversation they never saw.
    var isWeak: Bool {
        ["date", "resumption", "error", "recent-turn"].contains(titleSource)
    }
}

/// What the user actually thinks they own: a project, and everything the
/// agents left in it.
///
/// The app used to present this as two screens because the code arrived as
/// two subsystems -- scree found workspaces and worktrees, mothball judged
/// repos for retirement. Nobody outside the codebase has a reason to know
/// that boundary: a session, a worktree, a git state and a retirement
/// verdict are all facts about the same thing, and splitting them across
/// two sidebar entries made the user assemble the object themselves.
///
/// Worktrees are evidence here, not identity. `affectionate-cohen-f52bc6`
/// is a useful thing to show once you know which project you are looking
/// at, and a terrible thing to sort a list by.
struct WorkProject: Identifiable {
    let path: String
    var sessions: [SessionIndexEntry] = []
    var worktrees: [ScreeWorktreeItem] = []

    /// What is known about this project's git state -- including the two
    /// cases where the answer is that nothing is known.
    ///
    /// It was an `ArchiveCandidate?`, and `nil` had to mean three
    /// different things at once: judged and clean, never looked at
    /// because the scan stopped at its root cap, and looked at but
    /// unreadable. All three drew the same row, which is the collapse of
    /// unknown into none that this project keeps having to undo.
    var git: GitAssessmentState = .notApplicable

    /// The judged repo, when there is one.
    var assessment: ArchiveCandidate? {
        if case .assessed(let candidate) = git { return candidate }
        return nil
    }

    /// The same assessment, when it says the repo may be retired at all.
    /// `[은퇴 검토]` is offered from this, never from `assessment`: a repo
    /// with uncommitted work has a git state worth showing and no
    /// retirement to review.
    var candidate: ArchiveCandidate? {
        guard let assessment, assessment.isRetirementEligible else { return nil }
        return assessment
    }

    var id: String { WorkProjectBuilder.canonical(path) }

    /// Conversations that exist but could not be placed in a project.
    var isUnassigned: Bool { path == WorkProjectBuilder.unassignedID }

    var name: String {
        isUnassigned ? "연결되지 않은 대화" : URL(fileURLWithPath: path).lastPathComponent
    }

    /// Sessions that hold a readable conversation, newest first.
    var conversations: [SessionIndexEntry] {
        sessions.filter(\.isReadable)
    }

    var conversationCount: Int { conversations.count }

    var totalBytes: Int64 { sessions.reduce(0) { $0 + $1.sizeBytes } }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// Which agents worked here, in a stable order.
    var tools: [String] {
        var seen: [String] = []
        for session in sessions where !seen.contains(session.tool) {
            seen.append(session.tool)
        }
        return seen
    }

    var lastActive: String? { sessions.first?.lastActive }

    /// Git facts that mean work here could be lost.
    ///
    /// Only the risks. "Dormant for 400 days" is information -- it is the
    /// *reason* a repo is a good retirement candidate -- and listing it
    /// beside uncommitted work put a warning triangle on exactly the
    /// repos that were fine.
    var gitRisks: [String] {
        guard let verdict = assessment?.verdict else { return [] }
        return verdict.reasons.compactMap { reason in
            switch reason {
            case .dirtyWorkingTree: return "커밋 안 된 변경"
            case .unpushedCommits(let count): return "미푸시 \(count)개"
            case .noRemoteConfigured: return "원격 없음"
            case .noUpstreamConfigured: return "업스트림 미설정"
            case .noCommitsYet: return "커밋 없음"
            case .dormant, .recentActivity, .fullyPushed: return nil
            }
        }
    }

    /// Git facts that describe the project without warning about it.
    var gitNotes: [String] {
        guard let verdict = assessment?.verdict else { return [] }
        return verdict.reasons.compactMap { reason in
            switch reason {
            case .dormant(let days): return "\(days)일간 미사용"
            case .recentActivity(let days): return "최근 활동 \(days)일 전"
            case .fullyPushed: return "원격에 모두 반영됨"
            default: return nil
            }
        }
    }

    /// Worktrees holding work that exists nowhere else.
    ///
    /// scree's vocabulary is `protected` / `rebuildable` / `unreadable`;
    /// there is no `reclaimable`, so a filter written against that name
    /// matched everything and reported every rebuildable worktree as
    /// something to protect.
    var protectedWorktrees: [ScreeWorktreeItem] {
        worktrees.filter { $0.verdict == "protected" }
    }

    /// Worktrees the judgment could not read. Worth flagging -- an
    /// unreadable worktree is not a safe one -- but not worth calling
    /// protected, which claims knowledge nobody has.
    var unverifiedWorktrees: [ScreeWorktreeItem] {
        worktrees.filter { $0.verdict == "unreadable" }
    }

    /// True when something here would be stranded by a deletion. Drives the
    /// row's marker, and nothing else -- it is not a retirement verdict.
    var needsAttention: Bool {
        !protectedWorktrees.isEmpty || !unverifiedWorktrees.isEmpty || !gitRisks.isEmpty
    }

    /// What a search matches. Worktree branch names included: they are poor
    /// identity but perfectly good search terms.
    var searchHaystack: String {
        ([name, path] + tools + worktrees.map(\.branch)).joined(separator: "\n").lowercased()
    }
}

/// Which project's retirement sheet is open, by identity rather than by
/// value. See the `sheet(item:)` call site for why.
struct RetirementReviewTarget: Identifiable, Equatable {
    let id: String
}

/// Everything one git scan established, including what it did not reach.
struct RepoScanOutcome {
    let candidates: [ArchiveCandidate]
    /// Repo path to the reason it could not be read.
    let failures: [String: String]
    /// Repo paths the root cap left out entirely.
    let notScanned: [String]

    var failureCount: Int { failures.count }
}

/// What a scan was able to establish about one repository.
///
/// The two failure cases are kept apart because they call for different
/// things from the reader: a repo the scan never reached is answered by
/// raising the cap, and a repo it could not read is answered by looking
/// at the repo.
enum GitAssessmentState: Equatable {
    /// A scanner read the repo and judged it.
    case assessed(ArchiveCandidate)

    /// Known to be a git repository, and the scan stopped before it. Not
    /// a statement about the repo at all.
    case notScanned

    /// Reached and unreadable -- a corrupt `.git`, a permission wall, a
    /// git process that timed out.
    case failed(String)

    /// Nothing here claims to be a git repository, so there is no git
    /// answer to withhold.
    case notApplicable

    static func == (lhs: GitAssessmentState, rhs: GitAssessmentState) -> Bool {
        switch (lhs, rhs) {
        case (.assessed(let a), .assessed(let b)): return a.id == b.id
        case (.notScanned, .notScanned), (.notApplicable, .notApplicable): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }

    /// The one line a row shows when there is no judgment to show. `nil`
    /// when the project never claimed to be a repository.
    var unknownReason: String? {
        switch self {
        case .assessed, .notApplicable: return nil
        case .notScanned: return "Git 상태 미확인 · 이번 검사 범위 밖"
        case .failed: return "Git 상태 미확인 · 저장소를 읽지 못했습니다"
        }
    }
}

/// Identity plus contents. `ArchiveCandidate` and `ScreeWorktreeItem` are
/// not themselves `Equatable`, and the comparisons this type is actually
/// used for -- did the list change, is this the same project -- are
/// answered by what the rows show.
extension WorkProject: Equatable {
    static func == (lhs: WorkProject, rhs: WorkProject) -> Bool {
        lhs.path == rhs.path
            && lhs.sessions == rhs.sessions
            && lhs.worktrees.map(\.id) == rhs.worktrees.map(\.id)
            && lhs.git == rhs.git
    }
}

enum WorkProjectBuilder {
    /// The group holding conversations whose workspace could not be
    /// resolved. Its path is not a real path, and `isUnassigned` is how
    /// the UI knows not to treat it as one.
    static let unassignedID = "\u{0}unassigned"

    /// Groups every session, worktree and repo assessment under the
    /// project it belongs to.
    ///
    /// The roll-up is the whole point. An agent worktree records its own
    /// directory as the workspace, so a repo with twenty agent runs
    /// produced twenty unrelated-looking entries -- exactly the low-level
    /// artifact view that made the old screens hard to read.
    ///
    /// `roots` comes from every git path the audit saw, not from the
    /// retirement candidates: whether `/repo/subdir` belongs to `/repo`
    /// is a fact about the filesystem, and letting it depend on whether
    /// `/repo` survived the archive classifier made project identity a
    /// function of retirement eligibility.
    static func build(
        sessions: [SessionIndexEntry],
        worktrees: [ScreeWorktreeItem],
        assessments: [ArchiveCandidate],
        gitRoots: [String] = [],
        // Repos the scan could not read, and repos it never reached.
        // Passed in rather than inferred from the absence of an
        // assessment, because absence cannot tell the two apart -- and
        // telling them apart is the whole point.
        scanFailures: [String: String] = [:],
        notScanned: [String] = []
    ) -> [WorkProject] {
        var roots: Set<String> = []
        for assessment in assessments { roots.insert(canonical(assessment.pathText)) }
        for worktree in worktrees { roots.insert(canonical(worktree.repo)) }
        for root in gitRoots { roots.insert(canonical(root)) }

        var projects: [String: WorkProject] = [:]
        // Case-folded key, real spelling for display. macOS filesystems are
        // case-insensitive by default and the providers each record their
        // own casing of the same directory, which is why scree's lineage
        // folds case too -- without it `/Users/example/Ploidy` and
        // `/Users/example/ploidy` split into two projects that are one
        // folder.
        func upsert(_ path: String, _ mutate: (inout WorkProject) -> Void) {
            let key = canonical(path)
            var entry = projects[key] ?? WorkProject(path: path)
            mutate(&entry)
            projects[key] = entry
        }

        for session in sessions {
            guard !session.workspace.isEmpty else {
                // Discovered but unplaceable. Dropping these would mean
                // finding a conversation and then hiding it, which is the
                // opposite of what this app is for -- and the Gemini
                // collector deliberately leaves the workspace empty rather
                // than guessing, so real conversations land here.
                upsert(unassignedID) { $0.sessions.append(session) }
                continue
            }
            upsert(projectRoot(for: session.workspace, roots: roots)) {
                $0.sessions.append(session)
            }
        }
        for worktree in worktrees {
            upsert(worktree.repo) { $0.worktrees.append(worktree) }
        }
        for assessment in assessments {
            upsert(assessment.pathText) { $0.git = .assessed(assessment) }
        }
        // Applied after the assessments, and only where none landed: a
        // repo that was both retried and judged is judged.
        for (path, reason) in scanFailures {
            upsert(path) { if case .notApplicable = $0.git { $0.git = .failed(reason) } }
        }
        for path in notScanned {
            upsert(path) { if case .notApplicable = $0.git { $0.git = .notScanned } }
        }

        return projects.values
            .map { project in
                var copy = project
                // Newest first, so the titles a row shows are the work the
                // person most likely came back for.
                copy.sessions.sort { $0.lastActive > $1.lastActive }
                return copy
            }
            .sorted { lhs, rhs in
                // Unplaceable conversations last: they are real, and they
                // are not what someone opening this screen is looking for.
                if lhs.isUnassigned != rhs.isUnassigned { return rhs.isUnassigned }
                return (lhs.lastActive ?? "") == (rhs.lastActive ?? "")
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : (lhs.lastActive ?? "") > (rhs.lastActive ?? "")
            }
    }

    /// The project a workspace belongs to.
    ///
    /// Agent worktrees are folded into their repo even when no scanner has
    /// reported that repo yet: the `/.claude/worktrees/<name>` shape is the
    /// convention this app creates itself, and waiting for a git scan to
    /// confirm it would leave the list looking like a pile of adjectives
    /// and surnames.
    static func projectRoot(for workspace: String, roots: Set<String>) -> String {
        let normalized = normalize(workspace)
        let folded = canonical(workspace)
        var best: String?
        // Fold the roots here rather than trusting the caller to. This is
        // the function every grouping decision goes through, and a caller
        // that passed real spellings would otherwise get case-sensitive
        // matching back without any sign that it had.
        for root in roots.map(canonical) {
            guard folded == root || folded.hasPrefix(root + "/") else { continue }
            if best == nil || root.count > best!.count { best = root }
        }
        if let best {
            // Return the caller's own spelling when the match is the whole
            // path, so a project keeps the casing it was recorded with.
            return folded == best ? normalized : String(normalized.prefix(best.count))
        }
        for marker in ["/.claude/worktrees/", "/.git/worktrees/"] {
            if let range = folded.range(of: marker) {
                return String(normalized.prefix(folded.distance(
                    from: folded.startIndex, to: range.lowerBound)))
            }
        }
        return normalized
    }

    /// The comparison key: trailing slash removed, case folded.
    static func canonical(_ path: String) -> String {
        normalize(path).lowercased()
    }

    private static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
