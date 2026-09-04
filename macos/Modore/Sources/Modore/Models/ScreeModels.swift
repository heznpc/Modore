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
    let registeredMissing: [ScreeRegisteredMissing]
    let worktreeDiscovery: ScreeWorktreeDiscovery

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
        registeredMissing = ((worktrees["registered_missing"] as? [[String: Any]]) ?? [])
            .map(ScreeRegisteredMissing.init)
        worktreeDiscovery = ScreeWorktreeDiscovery(json: worktrees)
    }

    var protectedWorktreeCount: Int {
        worktreeItems.filter { $0.verdict == "protected" }.count
    }
}

/// How much of the Mac the worktree inventory actually observed.
///
/// The automatic audit follows workspace paths already named by local
/// session metadata. It intentionally does not crawl broad home-directory
/// roots, so an empty `items` array cannot mean "this Mac has no worktrees".
struct ScreeWorktreeDiscovery: Equatable {
    let scope: String
    let globalComplete: Bool
    let observedWorkspaces: Int
    let unreadable: Int
    let truncated: Bool

    init(json: [String: Any]) {
        scope = JsonRead.string(json, "scope", "unspecified")
        globalComplete = JsonRead.bool(json, "global_complete") ?? false
        observedWorkspaces = JsonRead.int(json, "observed_workspaces")
        unreadable = JsonRead.int(json, "unreadable")
        truncated = JsonRead.bool(json, "truncated") ?? false
    }

    var emptyStateText: String {
        globalComplete
            ? "등록된 에이전트 워크트리가 없습니다."
            : "세션 기록이 가리킨 경로에서는 에이전트 워크트리를 찾지 못했습니다."
    }

    var coverageText: String {
        if globalComplete {
            return "디스크 전체 범위를 확인했습니다."
        }
        var text = scope == "session-metadata"
            ? "세션 기록의 작업 경로 \(observedWorkspaces)곳만 확인했습니다. 디스크 전체 검색 결과가 아닙니다."
            : "확인 범위가 제한되어 디스크 전체 검색 결과로 해석할 수 없습니다."
        if unreadable > 0 {
            text += " \(unreadable)곳은 읽지 못했습니다."
        }
        if truncated {
            text += " 시간 또는 수량 한도에서 확인을 멈췄습니다."
        }
        return text
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
    /// `nil` means the bounded workspace probe timed out or could not classify
    /// the path. It must not be rendered as a confirmed deletion.
    let storyAlive: Bool?
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
        storyAlive = JsonRead.bool(json, "story_alive")
        ownerDeleted = JsonRead.bool(json, "owner_deleted") ?? false
    }

    var workspaceLastComponent: String {
        (workspace as NSString).lastPathComponent
    }

    var workspaceStateText: String {
        switch storyAlive {
        case true: return "작업 경로 현존"
        case false: return "작업 경로 소멸"
        case nil: return "작업 경로 확인 못함"
        }
    }
}

struct ScreeWorktreeItem: Identifiable {
    var id: String { path }
    let path: String
    let repo: String
    let branch: String
    /// `nil` means the registry query failed or exhausted its shared budget.
    /// Unknown must not collapse to the same value as a confirmed anchor break.
    let registered: Bool?
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
        registered = JsonRead.bool(json, "registered")
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
        if verdict == "unreadable" {
            return registered == false
                ? "git 확인 실패 · 등록 끊김 · 재검사 필요"
                : "git 확인 실패 · 재검사 필요"
        }
        var parts: [String] = []
        if dirty { parts.append("dirty") }
        if unpushedCommits > 0 { parts.append("unpushed \(unpushedCommits)") }
        if parts.isEmpty { parts.append("clean") }
        if registered == nil { parts.append("등록 여부 확인 실패") }
        if registered == false { parts.append("등록 끊김") }
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

struct ScreeRegisteredMissing: Identifiable {
    var id: String { "\(repo)\n\(path)" }
    let repo: String
    let path: String

    init(json: [String: Any]) {
        repo = JsonRead.string(json, "repo")
        path = JsonRead.string(json, "path")
    }

    var displayLabel: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

struct ScreeLineageSummary {
    let total: Int
    let aliveGit: Int
    let alivePlain: Int
    let vanished: Int
    let unknown: Int
    let caseGhosts: Int

    init(json: [String: Any]) {
        total = JsonRead.int(json, "total")
        aliveGit = JsonRead.int(json, "alive_git")
        alivePlain = JsonRead.int(json, "alive_plain")
        vanished = JsonRead.int(json, "vanished")
        unknown = JsonRead.int(json, "unknown")
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
    /// `nil` preserves a timeout or unreadable path instead of inventing a
    /// negative existence or repository verdict.
    let exists: Bool?
    let hasGit: Bool?
    let caseVariants: [String]

    init(json: [String: Any]) {
        path = JsonRead.string(json, "path")
        exists = JsonRead.bool(json, "exists")
        hasGit = JsonRead.bool(json, "has_git")
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
    let workspaceExists: Bool?
    /// `session` or `workspace_state`, straight from scree.
    let kind: String
    let sizeBytes: Int64
    /// `false` means the fast metadata index deliberately skipped a recursive
    /// unit walk. The explicit backup receipt computes the exact byte total.
    let sizeComplete: Bool?
    let lastActive: String
    /// Provider identity shared by every physical rollout fragment.
    let providerSessionId: String?
    /// Newest first. Older runtimes omit this and imply one physical source.
    let artifactSources: [String]
    let segmentCount: Int

    var id: String {
        providerSessionId.map { "\(tool.lowercased()):\($0)" } ?? source
    }
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
        case "claude desktop": return .claudeDesktop
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

    /// Raw backup support is narrower than conversation readability. Gemini
    /// can be inspected, for example, but scree has no byte-preserving Gemini
    /// backup contract. Keep the button coupled to the providers the backup
    /// engine actually accepts, including Desktop's conversation-unit handle.
    var supportsOriginalBackup: Bool {
        ["claude", "claude desktop", "codex"].contains(tool.lowercased())
    }

    var supportsConversationExport: Bool {
        isReadable && (
            sourceURL.pathExtension.lowercased() == "jsonl"
                || tool.caseInsensitiveCompare("Claude Desktop") == .orderedSame
        )
    }

    var subtitle: String {
        var parts = [tool, isReadable ? "대화" : "편집기 상태", lastActive]
        if segmentCount > 1 {
            parts.append("기록 조각 \(segmentCount)개")
        }
        parts.append(sizeComplete == false ? "전체 크기는 백업 시 계산" : sizeText)
        if !workspace.isEmpty {
            if workspaceExists == false {
                parts.append("작업 경로 소멸")
            } else if workspaceExists == nil {
                parts.append("작업 경로 확인 못함")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// What a search matches against. Path included: people look for a
    /// session by the project it ran in as often as by its name.
    var searchHaystack: String {
        "\(displayLabel)\n\(workspace)\n\(tool)\n\(artifactSources.joined(separator: "\n"))"
            .lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case tool, source, workspace, workspaceExists, kind, sizeBytes
        case sizeComplete, lastActive, sessionId, artifactSources, segmentCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tool = try values.decode(String.self, forKey: .tool)
        source = try values.decode(String.self, forKey: .source)
        workspace = try values.decode(String.self, forKey: .workspace)
        workspaceExists = try values.decodeIfPresent(Bool.self, forKey: .workspaceExists)
        kind = try values.decode(String.self, forKey: .kind)
        sizeBytes = try values.decode(Int64.self, forKey: .sizeBytes)
        sizeComplete = try values.decodeIfPresent(Bool.self, forKey: .sizeComplete)
        lastActive = try values.decode(String.self, forKey: .lastActive)
        providerSessionId = try values.decodeIfPresent(String.self, forKey: .sessionId)
        artifactSources = try values.decodeIfPresent(
            [String].self, forKey: .artifactSources
        ) ?? [source]
        segmentCount = try values.decodeIfPresent(
            Int.self, forKey: .segmentCount
        ) ?? artifactSources.count
    }
}

/// The index plus how much of it was returned.
struct SessionIndex: Decodable, Equatable {
    /// Sessions before the cap, so the view can say what it is not showing
    /// rather than presenting a truncated list as the whole machine.
    let total: Int
    let artifactTotal: Int
    let sessions: [SessionIndexEntry]
    /// Store-by-store discovery coverage. A result from an older runtime that
    /// omitted it decodes as incomplete rather than silently implying that the
    /// visible rows are the whole machine.
    let coverage: SessionIndexCoverage

    init(
        total: Int,
        artifactTotal: Int? = nil,
        sessions: [SessionIndexEntry],
        coverage: SessionIndexCoverage = .unknown
    ) {
        self.total = total
        self.artifactTotal = artifactTotal ?? total
        self.sessions = sessions
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey {
        case total, artifactTotal, sessions, coverage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        total = try values.decode(Int.self, forKey: .total)
        artifactTotal = try values.decodeIfPresent(
            Int.self, forKey: .artifactTotal
        ) ?? total
        sessions = try values.decode([SessionIndexEntry].self, forKey: .sessions)
        coverage = try values.decodeIfPresent(
            SessionIndexCoverage.self,
            forKey: .coverage
        ) ?? .unknown
    }
}

struct SessionIndexCoverage: Decodable, Equatable {
    let complete: Bool
    let stores: [SessionIndexStoreCoverage]

    static let unknown = SessionIndexCoverage(complete: false, stores: [])

    /// A partial index remains useful, but an empty/short list must never be
    /// presented as everything on the Mac when a provider root was unreadable
    /// or contained records this build could not recognize.
    var warningText: String? {
        guard !complete else { return nil }
        let issues = stores.compactMap(\.issueText)
        guard !issues.isEmpty else {
            return "일부 로컬 대화 저장소를 끝까지 확인하지 못했습니다. 현재 목록을 전체 기록으로 단정하지 않습니다."
        }
        return "일부 로컬 대화 저장소를 끝까지 확인하지 못했습니다: "
            + issues.joined(separator: " · ")
            + ". 현재 목록을 전체 기록으로 단정하지 않습니다."
    }
}

struct SessionIndexStoreCoverage: Decodable, Equatable, Identifiable {
    var id: String { store }
    let store: String
    let status: String
    let count: Int
    let unrecognized: Int

    var issueText: String? {
        switch status {
        case "ok", "missing":
            return unrecognized > 0 ? "\(store) 형식 미인식 \(unrecognized)개" : nil
        case "unreadable":
            return "\(store) 읽기 실패"
        case "truncated":
            return "\(store) 확인 중단"
        case "unrecognized":
            return "\(store) 형식 미인식 \(max(1, unrecognized))개"
        default:
            return "\(store) 상태 확인 불가"
        }
    }
}


/// One matching turn from `scree.py search`.
struct SessionSearchMatch: Decodable, Identifiable, Equatable {
    let source: String
    let tool: String
    let workspace: String
    let lastActive: String
    /// Session-level provenance only. A resumed session's mtime must never be
    /// substituted for the matching turn's own `at` timestamp.
    let lastActiveEpoch: Double?
    /// The matching turn's own provider timestamp. Never replaced with the
    /// session mtime: a resumed conversation can be weeks newer than the hit.
    let at: String?
    /// Provider event identity when the store exposes one; used by scree to
    /// collapse Claude resume/fork replay across transcript files.
    let eventId: String?
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

    var supportsOriginalBackup: Bool {
        ["claude", "claude desktop", "codex"].contains(tool.lowercased())
    }

    var supportsConversationExport: Bool {
        provider.keepsTranscripts && (
            sourceURL.pathExtension.lowercased() == "jsonl"
                || tool.caseInsensitiveCompare("Claude Desktop") == .orderedSame
        )
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
            switch truncatedReason {
            case "time":
                notes.append("시간이 오래 걸려 \(scannedSessions)/\(totalSessions)개까지만 훑었습니다.")
            case "discovery":
                notes.append("일부 로컬 대화 저장소를 확인하지 못했습니다.")
            default:
                notes.append("결과가 많아 일부만 표시했습니다. 검색어를 좁히세요.")
            }
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
/// provider tool invocation containing that phrase, a Modore cleanup receipt,
/// and a later free-space sample establish four different things.
struct ScreeEvidenceResult: Decodable, Equatable {
    let query: String
    let conversationMentions: [SessionSearchMatch]
    let providerToolInvocations: [ScreeProviderToolInvocation]
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
            switch truncatedReason {
            case "time":
                notes.append("시간 제한으로 \(scannedSessions)/\(totalSessions)개 대화까지만 확인했습니다.")
            case "discovery":
                notes.append("일부 로컬 대화 저장소를 확인하지 못했습니다.")
            default:
                notes.append("결과 제한에 닿아 모든 대화를 확인하지 못했습니다.")
            }
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
        guard conversationMentions.isEmpty && providerToolInvocations.isEmpty else {
            return "대화 언급과 provider 도구 호출 기록을 종류별로 표시합니다."
        }
        if definitive {
            return "확인한 모든 대화에서 이 문구의 언급이나 provider 도구 기록을 찾지 못했습니다."
        }
        return "아직 일치하는 언급이나 provider 도구 기록을 찾지 못했습니다."
    }
}

enum ScreeEvidenceKind: String, CaseIterable {
    case conversationMention = "conversation_mention"
    case providerToolInvocation = "provider_tool_invocation"
    case modoreCleanupReceipt = "modore_cleanup_receipt"
    case filesystemObservation = "filesystem_observation"

    var label: String {
        switch self {
        case .conversationMention: return "언급됨"
        case .providerToolInvocation: return "Provider 도구 기록"
        case .modoreCleanupReceipt: return "Modore 조치 기록"
        case .filesystemObservation: return "후속 변화 관찰됨"
        }
    }
}

struct ScreeProviderToolInvocation: Decodable, Equatable {
    let kind: String
    let command: String
    let at: String
    let callId: String
    /// requested/completed/failed/denied/unknown, decided by scree after
    /// correlating provider call and result records.
    let status: String
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
    let reclaimedKB: Int64?
    let physicalDeltaKB: Int64?
}

struct ScreeFilesystemObservation: Decodable, Equatable {
    let kind: String
    let at: String
    let freeKB: Int64
    let dropKB: Int64
    let status: String
}
