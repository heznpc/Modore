import Foundation

/// Decodes `python3 scripts/scree.py report --json`. scree is metadata-only and
/// read-only: this model surfaces its judgment, it never triggers a delete.
struct ScreeReport {
    let contract: String
    let stores: [ScreeStoreStatus]
    let unresolvedSessions: Int
    let lineageSummary: ScreeLineageSummary
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

    init(json: [String: Any]) {
        tool = JsonRead.string(json, "tool")
        workspace = JsonRead.string(json, "workspace")
        source = JsonRead.string(json, "source")
        daysLeft = JsonRead.int(json, "days_left")
        sizeBytes = JsonRead.int(json, "size_bytes")
        storyAlive = JsonRead.bool(json, "story_alive") ?? false
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
    }

    var pathLastComponent: String {
        (path as NSString).lastPathComponent
    }

    var reasonText: String {
        var parts: [String] = []
        if dirty { parts.append("dirty") }
        if unpushedCommits > 0 { parts.append("unpushed \(unpushedCommits)") }
        if parts.isEmpty { parts.append("clean") }
        return parts.joined(separator: " · ")
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
