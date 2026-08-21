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
    /// This project's git state, for every repo the scan could judge --
    /// not only the archivable ones. Absent when no scan has reached it.
    var assessment: ArchiveCandidate?

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

/// Identity plus contents. `ArchiveCandidate` and `ScreeWorktreeItem` are
/// not themselves `Equatable`, and the comparisons this type is actually
/// used for -- did the list change, is this the same project -- are
/// answered by what the rows show.
extension WorkProject: Equatable {
    static func == (lhs: WorkProject, rhs: WorkProject) -> Bool {
        lhs.path == rhs.path
            && lhs.sessions == rhs.sessions
            && lhs.worktrees.map(\.id) == rhs.worktrees.map(\.id)
            && lhs.assessment?.id == rhs.assessment?.id
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
        gitRoots: [String] = []
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
            upsert(assessment.pathText) { $0.assessment = assessment }
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
