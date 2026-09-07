import Foundation

enum CleanupTier: Int, Comparable, Sendable {
    case safe = 0
    case rebuild = 1

    static func < (lhs: CleanupTier, rhs: CleanupTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .safe: return "바로 다시 생겨도 되는 캐시"
        case .rebuild: return "필요할 때 다시 받거나 빌드하는 데이터"
        }
    }

    var shortTitle: String {
        switch self {
        case .safe: return "캐시"
        case .rebuild: return "재생성 필요"
        }
    }
}

struct CleanupExecutionRequest: Equatable, Sendable {
    let recipeID: String
    let target: String

    static func isRequired(for recipeID: String) -> Bool {
        recipeID == "project_residue" || recipeID == "transient_workspace"
    }

    init?(item: StorageItem) {
        guard Self.isRequired(for: item.cleanupID),
              item.kind == item.cleanupID,
              item.path.hasPrefix("/"),
              !item.path.isEmpty,
              !item.path.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else {
            return nil
        }
        recipeID = item.cleanupID
        target = item.path
    }

    var protocolData: Data {
        Data("version\t1\nkind\t\(recipeID)\ntarget\t\(target)\n".utf8)
    }
}

struct CleanupPlanEntry: Identifiable {
    let preview: CleanupPreview
    let tier: CleanupTier
    let request: CleanupExecutionRequest?

    var id: String { preview.recipeID + "\u{0}" + (request?.target ?? "") }
}

struct CleanupRecoveryPlan: Identifiable {
    static let minimumApprovalValidity: TimeInterval = 30

    let id: UUID
    let createdAt: Date
    let baselineFreeBytes: Int64
    let requestedGainBytes: Int64
    let entries: [CleanupPlanEntry]

    init(
        id: UUID = UUID(), createdAt: Date = Date(),
        baselineFreeBytes: Int64, requestedGainBytes: Int64,
        entries: [CleanupPlanEntry]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.baselineFreeBytes = baselineFreeBytes
        self.requestedGainBytes = requestedGainBytes
        self.entries = entries
    }

    var desiredFreeBytes: Int64? { StorageBytes.adding(baselineFreeBytes, requestedGainBytes) }
    var readyEntries: [CleanupPlanEntry] { entries.filter { $0.preview.canExecute } }
    var blockedEntries: [CleanupPlanEntry] { entries.filter { !$0.preview.canExecute } }
    var estimatedBytes: Int64? {
        readyEntries.reduce(Optional(Int64(0))) { total, entry in
            guard let total, let bytes = entry.preview.estimatedBytes else { return nil }
            return StorageBytes.adding(total, bytes)
        }
    }
    var earliestApprovalExpiry: Date? {
        let expiries = readyEntries.compactMap(\.preview.approvalExpiresAt)
        guard expiries.count == readyEntries.count else { return nil }
        return expiries.min()
    }
    var canExecute: Bool { canExecute(at: Date()) }

    func canExecute(at date: Date) -> Bool {
        requestedGainBytes > 0 && desiredFreeBytes != nil && !readyEntries.isEmpty && readyEntries.allSatisfy {
            $0.preview.approvalIsFresh(
                at: date,
                minimumRemaining: Self.minimumApprovalValidity
            )
        }
    }

    func approvalStatusText(at date: Date) -> String {
        guard let earliestApprovalExpiry else { return "승인 정보를 다시 측정해야 합니다" }
        let remaining = Int(earliestApprovalExpiry.timeIntervalSince(date).rounded(.down))
        guard remaining >= Int(Self.minimumApprovalValidity) else {
            return "승인 만료 · 실행 전 다시 측정"
        }
        return String(format: "승인 유효 %d:%02d", remaining / 60, remaining % 60)
    }
}

struct CleanupRecoveryProgress: Equatable {
    let completedCount: Int
    let totalCount: Int
    let currentLabel: String

    var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}

struct CleanupRecoveryItemResult: Identifiable {
    let recipeID: String
    let requestTarget: String
    let label: String
    let status: String
    let reclaimedBytes: Int64?
    let physicalDeltaBytes: Int64?
    let receipt: String
    let detail: String

    var id: String { recipeID + "\u{0}" + requestTarget }
    var succeeded: Bool { status == "complete" }
}

struct CleanupRecoveryResult {
    let baselineFreeBytes: Int64
    let finalFreeBytes: Int64?
    let desiredFreeBytes: Int64
    let plannedCount: Int
    let items: [CleanupRecoveryItemResult]
    let stoppedAfterFailure: Bool
    let rescanScheduled: Bool

    var freeSpaceMeasured: Bool { finalFreeBytes != nil }
    var actualChangeBytes: Int64? { finalFreeBytes.map { $0 - baselineFreeBytes } }
    var goalMet: Bool { finalFreeBytes.map { $0 >= desiredFreeBytes } ?? false }
    var succeededCount: Int { items.filter(\.succeeded).count }
    var skippedCount: Int { max(0, plannedCount - items.count) }
    var failedItems: [CleanupRecoveryItemResult] { items.filter { !$0.succeeded } }
}
