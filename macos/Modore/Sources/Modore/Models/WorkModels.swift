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
    /// Present only when the retirement judgment has run for this project.
    /// Its absence is why `[은퇴 검토]` is offered rather than assumed.
    var candidate: ArchiveCandidate?

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

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

    /// Git facts worth a glance on the row itself, not buried in a sheet.
    var gitFlags: [String] {
        guard let verdict = candidate?.verdict else { return [] }
        var flags: [String] = []
        for reason in verdict.reasons {
            switch reason {
            case .dirtyWorkingTree: flags.append("커밋 안 된 변경")
            case .unpushedCommits(let count): flags.append("미푸시 \(count)개")
            case .noRemoteConfigured: flags.append("원격 없음")
            case .noUpstreamConfigured: flags.append("업스트림 미설정")
            case .noCommitsYet: flags.append("커밋 없음")
            case .dormant(let days): flags.append("\(days)일간 미사용")
            case .recentActivity, .fullyPushed: continue
            }
        }
        return flags
    }

    /// Worktrees this project must not lose, by the worktree judgment's own
    /// verdict.
    var protectedWorktrees: [ScreeWorktreeItem] {
        worktrees.filter { $0.verdict != "reclaimable" }
    }

    /// True when something here would be stranded by a deletion. Drives the
    /// row's marker, and nothing else -- it is not a retirement verdict.
    var needsAttention: Bool {
        !protectedWorktrees.isEmpty || !gitFlags.isEmpty
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
            && lhs.candidate?.id == rhs.candidate?.id
    }
}

enum WorkProjectBuilder {
    /// Groups every session, worktree and retirement candidate under the
    /// project it belongs to.
    ///
    /// The roll-up is the whole point. An agent worktree records its own
    /// directory as the workspace, so a repo with twenty agent runs
    /// produced twenty unrelated-looking entries -- which is exactly the
    /// low-level artifact view that made the old screens hard to read.
    /// Longest known root wins, so a worktree lands under its repo and a
    /// subdirectory lands under the project that contains it.
    static func build(
        sessions: [SessionIndexEntry],
        worktrees: [ScreeWorktreeItem],
        candidates: [ArchiveCandidate]
    ) -> [WorkProject] {
        var roots: Set<String> = []
        for candidate in candidates { roots.insert(candidate.pathText) }
        for worktree in worktrees { roots.insert(worktree.repo) }

        var projects: [String: WorkProject] = [:]
        func project(_ path: String) -> WorkProject {
            projects[path] ?? WorkProject(path: path)
        }

        for session in sessions {
            guard !session.workspace.isEmpty else { continue }
            let key = projectRoot(for: session.workspace, roots: roots)
            var entry = project(key)
            entry.sessions.append(session)
            projects[key] = entry
        }
        for worktree in worktrees {
            var entry = project(worktree.repo)
            entry.worktrees.append(worktree)
            projects[worktree.repo] = entry
        }
        for candidate in candidates {
            var entry = project(candidate.pathText)
            entry.candidate = candidate
            projects[candidate.pathText] = entry
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
                (lhs.lastActive ?? "") == (rhs.lastActive ?? "")
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
        var best: String?
        for root in roots {
            let candidate = normalize(root)
            guard normalized == candidate || normalized.hasPrefix(candidate + "/") else { continue }
            if best == nil || candidate.count > best!.count { best = candidate }
        }
        if let best { return best }
        for marker in ["/.claude/worktrees/", "/.git/worktrees/"] {
            if let range = normalized.range(of: marker) {
                return String(normalized[normalized.startIndex..<range.lowerBound])
            }
        }
        return normalized
    }

    private static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
