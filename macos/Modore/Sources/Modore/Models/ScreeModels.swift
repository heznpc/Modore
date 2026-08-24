import Foundation
import MothballCore

/// Decodes `python3 scripts/scree.py report --json`. scree is metadata-only and
/// read-only: this model surfaces its judgment, it never triggers a delete.
struct ScreeReport {
    let contract: String
    let stores: [ScreeStoreStatus]
    let unresolvedSessions: Int
    let lineageSummary: ScreeLineageSummary
    let lineagePaths: [ScreeLineagePath]
    let retentionStores: [ScreeRetentionStore]
    let expiring: [ScreeExpiringSession]
    let worktreeItems: [ScreeWorktreeItem]
    let registeredMissing: [String]

    init?(json: [String: Any]) {
        contract = JsonRead.string(json, "contract")
        stores = ((json["stores"] as? [[String: Any]]) ?? []).map(ScreeStoreStatus.init)
        unresolvedSessions = JsonRead.int(json, "unresolved_sessions")

        let lineage = json["lineage"] as? [String: Any] ?? [:]
        lineageSummary = ScreeLineageSummary(json: lineage["summary"] as? [String: Any] ?? [:])
        lineagePaths = ((lineage["paths"] as? [[String: Any]]) ?? []).map(ScreeLineagePath.init)

        let retention = json["retention"] as? [String: Any] ?? [:]
        retentionStores = ((retention["stores"] as? [[String: Any]]) ?? []).map(ScreeRetentionStore.init)
        expiring = ((retention["expiring"] as? [[String: Any]]) ?? [])
            .map(ScreeExpiringSession.init)
            .sorted { $0.daysLeft < $1.daysLeft }

        let worktrees = json["worktrees"] as? [String: Any] ?? [:]
        worktreeItems = ((worktrees["items"] as? [[String: Any]]) ?? []).map(ScreeWorktreeItem.init)
        registeredMissing = (worktrees["registered_missing"] as? [String]) ?? []
    }

    var protectedWorktreeCount: Int {
        worktreeItems.filter { $0.verdict == "protected" }.count
    }
}

struct ScreeStoreStatus: Identifiable {
    var id: String { store }
    let store: String
    let status: String
    let count: Int
    let unrecognized: Int

    init(json: [String: Any]) {
        store = JsonRead.string(json, "store")
        status = JsonRead.string(json, "status", "unknown")
        count = JsonRead.int(json, "count")
        unrecognized = JsonRead.int(json, "unrecognized")
    }
}

struct ScreeRetentionStore: Identifiable {
    var id: String { store }
    let store: String
    let sessions: Int
    let oldestDays: Int
    let stalled: Bool
    let mode: String
    let windowDays: Int?

    init(json: [String: Any]) {
        store = JsonRead.string(json, "store")
        sessions = JsonRead.int(json, "sessions")
        oldestDays = JsonRead.int(json, "oldest_days")
        stalled = JsonRead.bool(json, "stalled") ?? false
        mode = JsonRead.string(json, "mode", "rolling")
        windowDays = json["window_days"] != nil ? JsonRead.int(json, "window_days") : nil
    }
}

struct ScreeExpiringSession: Identifiable {
    var id: String { source }
    let tool: String
    let workspace: String
    let source: String
    let daysLeft: Int
    let sizeBytes: Int
    let storyAlive: Bool
    /// The owner deleted this conversation in the desktop app; only the
    /// transcript outlived that decision. Urging its rescue would argue with a
    /// choice already made, so the row says what happened instead.
    let ownerDeleted: Bool

    init(json: [String: Any]) {
        tool = JsonRead.string(json, "tool")
        workspace = JsonRead.string(json, "workspace")
        source = JsonRead.string(json, "source")
        daysLeft = JsonRead.int(json, "days_left")
        sizeBytes = JsonRead.int(json, "size_bytes")
        storyAlive = JsonRead.bool(json, "story_alive") ?? false
        ownerDeleted = JsonRead.bool(json, "owner_deleted") ?? false
    }

    var workspaceLastComponent: String {
        (workspace as NSString).lastPathComponent
    }
}

struct ScreeWorktreeItem: Identifiable {
    var id: String { path }
    let path: String
    let repo: String
    let branch: String
    let registered: Bool
    let dirty: Bool
    let unpushedCommits: Int
    let lastCommit: String
    let verdict: String
    let evidence: String
    /// scree.py's collect_worktrees() folds two different things into one
    /// items list: real secondary git worktrees, and the primary checkout
    /// itself when it's stranded on a non-default branch. Without this flag
    /// a stranded primary checkout renders identically to a disposable
    /// worktree copy -- same row shape, same verdict badge -- under a
    /// section header that says "agent worktrees", even though it's the
    /// user's actual repo directory, not a spare copy of it.
    let strayCheckout: Bool

    init(json: [String: Any]) {
        path = JsonRead.string(json, "path")
        repo = JsonRead.string(json, "repo")
        branch = JsonRead.string(json, "branch")
        registered = JsonRead.bool(json, "registered") ?? false
        dirty = JsonRead.bool(json, "dirty") ?? false
        unpushedCommits = JsonRead.int(json, "unpushed_commits")
        lastCommit = JsonRead.string(json, "last_commit")
        verdict = JsonRead.string(json, "verdict", "unknown")
        evidence = JsonRead.string(json, "evidence")
        strayCheckout = JsonRead.bool(json, "stray_checkout") ?? false
    }

    var pathLastComponent: String {
        (path as NSString).lastPathComponent
    }

    /// A stray checkout must never read like just another disposable
    /// worktree entry -- it's the repo directory itself.
    var displayLabel: String {
        strayCheckout ? "메인 체크아웃 · \(pathLastComponent)" : pathLastComponent
    }

    /// scree.py sends dirty/unpushed_commits as null when the git call for
    /// that specific signal failed -- JsonRead.bool/int already collapse
    /// that null to false/0 on decode, so by the time reasonText would
    /// normally build its "dirty"/"unpushed N"/"clean" phrase from those
    /// two fields, the failure is indistinguishable from a real, confirmed
    /// clean/pushed state. verdict is already the authoritative unreadable
    /// signal (see _worktree_verdict in scripts/scree.py); defer to it here
    /// instead of re-deriving a second, less honest description from
    /// already-collapsed booleans.
    var reasonText: String {
        guard verdict != "unreadable" else { return "git 확인 실패 · 재검사 필요" }
        var parts: [String] = []
        if dirty { parts.append("dirty") }
        if unpushedCommits > 0 { parts.append("unpushed \(unpushedCommits)") }
        if parts.isEmpty { parts.append("clean") }
        return parts.joined(separator: " · ")
    }

    var verdictLabel: String {
        switch verdict {
        case "protected": return "보호 대상"
        case "rebuildable": return "재구축 가능"
        default: return "확인 불가"
        }
    }

    var verdictSymbolName: String {
        switch verdict {
        case "protected": return "lock.fill"
        case "rebuildable": return "arrow.triangle.2.circlepath"
        default: return "questionmark.circle"
        }
    }
}

struct ScreeLineageSummary {
    let total: Int
    let aliveGit: Int
    let alivePlain: Int
    let vanished: Int
    let caseGhosts: Int

    init(json: [String: Any]) {
        total = JsonRead.int(json, "total")
        aliveGit = JsonRead.int(json, "alive_git")
        alivePlain = JsonRead.int(json, "alive_plain")
        vanished = JsonRead.int(json, "vanished")
        caseGhosts = JsonRead.int(json, "case_ghosts")
    }
}

/// One distinct work path scree's session records remember, casefold-
/// deduplicated by build_lineage on the Python side -- `path` is already a
/// single representative spelling, `caseVariants` (when non-empty) lists
/// every differently-cased form actually recorded. Metadata only: no
/// session content is involved in computing this.
struct ScreeLineagePath: Identifiable {
    var id: String { path }
    let path: String
    let exists: Bool
    let hasGit: Bool
    let caseVariants: [String]

    init(json: [String: Any]) {
        path = JsonRead.string(json, "path")
        exists = JsonRead.bool(json, "exists") ?? false
        hasGit = JsonRead.bool(json, "has_git") ?? false
        caseVariants = (json["case_variants"] as? [String]) ?? []
    }
}

/// One session as the browser lists it: metadata only, no body.
///
/// Deliberately not a `SessionBinding`. A binding is an answer to "which
/// repo does this belong to"; most of what the machine holds was never
/// asked that question, and requiring a binding to appear in a listing is
/// what kept the browser from existing.
struct SessionIndexEntry: Identifiable, Equatable, Decodable {
    let tool: String
    let source: String
    let workspace: String
    let workspaceExists: Bool
    /// `session` or `workspace_state`, straight from scree.
    let kind: String
    let sizeBytes: Int64
    let lastActive: String

    var id: String { source }
    var sourceURL: URL { URL(fileURLWithPath: source) }

    /// The workspace's last component, or the transcript's own name when
    /// no workspace was recorded — never a blank row.
    var displayLabel: String {
        guard !workspace.isEmpty else { return sourceURL.lastPathComponent }
        return URL(fileURLWithPath: workspace).lastPathComponent
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// Provider identity for the conversation cache key. The listing
    /// speaks scree's display names; the cache speaks MothballCore's.
    var provider: SessionProvider { Self.provider(forTool: tool) }

    static func provider(forTool tool: String) -> SessionProvider {
        switch tool.lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        case "gemini": return .gemini
        case "cursor": return .cursor
        case "windsurf": return .windsurf
        case "kiro": return .kiro
        case "antigravity": return .antigravity
        default: return .vscode
        }
    }

    /// Only agent transcripts hold a conversation to open; an editor's
    /// per-workspace state does not.
    ///
    /// Taken from the store's own kind rather than inferred from the
    /// provider name, so a store scree classifies one way and this app
    /// names another cannot drift into offering a conversation that is
    /// not there.
    var isReadable: Bool { kind == "session" && provider.keepsTranscripts }

    var subtitle: String {
        var parts = [tool, isReadable ? "대화" : "편집기 상태", lastActive, sizeText]
        if !workspace.isEmpty && !workspaceExists {
            parts.append("작업 경로 소멸")
        }
        return parts.joined(separator: " · ")
    }

    /// What a search matches against. Path included: people look for a
    /// session by the project it ran in as often as by its name.
    var searchHaystack: String {
        "\(displayLabel)\n\(workspace)\n\(tool)\n\(source)".lowercased()
    }
}

/// The index plus how much of it was returned.
struct SessionIndex: Decodable, Equatable {
    /// Sessions before the cap, so the view can say what it is not showing
    /// rather than presenting a truncated list as the whole machine.
    let total: Int
    let sessions: [SessionIndexEntry]
}


/// One matching turn from `scree.py search`.
struct SessionSearchMatch: Decodable, Identifiable, Equatable {
    let source: String
    let tool: String
    let workspace: String
    let lastActive: String
    /// Present in evidence payloads so their local-time display string can
    /// share a real timeline with UTC filesystem observations.
    let lastActiveEpoch: Double?
    let index: Int
    let role: String
    let isUser: Bool
    let snippet: String

    var id: String { "\(source)#\(index)" }
    var sourceURL: URL { URL(fileURLWithPath: source) }

    /// Same mapping the index uses, so a conversation opened from a
    /// search result lands on the same cache entry as one opened from a
    /// project row rather than fetching it twice under two keys.
    var provider: SessionProvider { SessionIndexEntry.provider(forTool: tool) }

    var displayLabel: String {
        workspace.isEmpty
            ? sourceURL.lastPathComponent
            : URL(fileURLWithPath: workspace).lastPathComponent
    }

    var subtitle: String {
        [displayLabel, tool, lastActive, isUser ? "나" : "에이전트"].joined(separator: " · ")
    }
}

/// A whole search, including how much of the machine it managed to read.
///
/// Coverage is part of the answer. "Nothing matched" and "I could not
/// finish looking" are different facts, and a search that quietly stops
/// at a budget while reporting nothing found is a lie by omission.
struct SessionSearchResult: Decodable, Equatable {
    let query: String
    let matches: [SessionSearchMatch]
    let scannedSessions: Int
    let totalSessions: Int
    let unreadableSessions: Int
    let coverage: String
    let truncatedReason: String?
    /// Whether "no match" may be stated as a fact. Decided by scree, not
    /// re-derived here, so every consumer withholds the conclusion on the
    /// same evidence.
    let definitive: Bool
    /// A hit means somebody said this, not that it was ever run.
    let evidenceKind: String

    /// The sweep reached every session. Not the same as being allowed to
    /// conclude anything -- see `definitive`.
    var isComplete: Bool { coverage == "complete" }

    /// What the screen must admit under the results.
    var caveat: String? {
        var notes: [String] = []
        if !isComplete {
            notes.append(truncatedReason == "time"
                ? "시간이 오래 걸려 \(scannedSessions)/\(totalSessions)개까지만 훑었습니다."
                : "결과가 많아 일부만 표시했습니다. 검색어를 좁히세요.")
        }
        if unreadableSessions > 0 {
            notes.append("세션 \(unreadableSessions)개는 읽지 못했습니다.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// What to say when nothing matched.
    ///
    /// Only a search that finished and could open everything is allowed
    /// the flat sentence. Anything else has to name what it could not
    /// see, or it turns "I do not know" into "there is none" -- the
    /// collapse this project keeps having to undo.
    var emptyResultText: String {
        if definitive { return "이 검색어가 나오는 대화가 없습니다." }
        if unreadableSessions > 0 && isComplete {
            let readable = max(0, totalSessions - unreadableSessions)
            return "읽을 수 있었던 대화 \(readable)개에서는 찾지 못했습니다."
                + " \(unreadableSessions)개는 확인하지 못했습니다."
        }
        return "아직 일치하는 대화를 찾지 못했습니다. 전부 훑지는 못했습니다."
    }
}

/// Four deliberately separate answers to a storage-history question.
///
/// They must not collapse into one count: a phrase in a conversation, a
/// provider tool call containing that phrase, Modore's own cleanup receipt,
/// and a later free-space sample establish four different things.
struct ScreeEvidenceResult: Decodable, Equatable {
    let query: String
    let conversationMentions: [SessionSearchMatch]
    let providerToolExecutions: [ScreeProviderToolExecution]
    let modoreCleanupReceipts: [ScreeCleanupReceipt]
    let filesystemObservations: [ScreeFilesystemObservation]
    let scannedSessions: Int
    let totalSessions: Int
    let unreadableSessions: Int
    let coverage: String
    let truncatedReason: String?
    /// Whether an absent conversation/tool-call match may be stated as
    /// absent. This is scree's conclusion and is never re-derived here.
    let definitive: Bool
    let masked: Bool

    var coverageNote: String? {
        guard !definitive else { return nil }
        var notes: [String] = []
        if coverage != "complete" {
            notes.append(truncatedReason == "time"
                ? "시간 제한으로 \(scannedSessions)/\(totalSessions)개 대화까지만 확인했습니다."
                : "결과 제한에 닿아 모든 대화를 확인하지 못했습니다.")
        }
        if unreadableSessions > 0 {
            notes.append("대화 \(unreadableSessions)개는 읽지 못했습니다.")
        }
        if notes.isEmpty {
            notes.append("모든 대화를 확인하지 못했습니다.")
        }
        return notes.joined(separator: " ") + " 기록이 없다고 단정하지 않습니다."
    }

    var matchSummary: String {
        guard conversationMentions.isEmpty && providerToolExecutions.isEmpty else {
            return "대화 언급과 provider 도구 기록을 종류별로 표시합니다."
        }
        if definitive {
            return "확인한 모든 대화에서 이 문구의 언급이나 provider 도구 기록을 찾지 못했습니다."
        }
        return "아직 일치하는 언급이나 provider 도구 기록을 찾지 못했습니다."
    }
}

enum ScreeEvidenceKind: String, CaseIterable {
    case conversationMention = "conversation_mention"
    case providerToolExecution = "provider_tool_execution"
    case modoreCleanupReceipt = "modore_cleanup_receipt"
    case filesystemObservation = "filesystem_observation"

    var label: String {
        switch self {
        case .conversationMention: return "언급됨"
        case .providerToolExecution: return "실행 기록 있음"
        case .modoreCleanupReceipt: return "Modore가 실행함"
        case .filesystemObservation: return "후속 변화 관찰됨"
        }
    }
}

struct ScreeProviderToolExecution: Decodable, Equatable {
    let kind: String
    let command: String
    let at: String
    let tool: String
    let source: String
    let workspace: String
    let lastActive: String
    let lastActiveEpoch: Double?
}

struct ScreeCleanupReceipt: Decodable, Equatable {
    let kind: String
    let at: String
    let recipeId: String
    let label: String
    let status: String
    let estimatedKB: Int64?
}

struct ScreeFilesystemObservation: Decodable, Equatable {
    let kind: String
    let at: String
    let freeKB: Int64
    let dropKB: Int64
    let status: String
}
