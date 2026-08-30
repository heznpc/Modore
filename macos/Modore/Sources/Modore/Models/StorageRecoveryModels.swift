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

    init?(item: StorageItem) {
        guard item.kind == "project_residue",
              item.cleanupID == "project_residue",
              item.path.hasPrefix("/"),
              !item.path.isEmpty,
              !item.path.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else {
            return nil
        }
        recipeID = item.cleanupID
        target = item.path
    }

    var protocolData: Data {
        Data("version\t1\nkind\tproject_residue\ntarget\t\(target)\n".utf8)
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
    let baselineFreeGB: Double
    let desiredFreeGB: Double
    let entries: [CleanupPlanEntry]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        baselineFreeGB: Double,
        desiredFreeGB: Double,
        entries: [CleanupPlanEntry]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.baselineFreeGB = baselineFreeGB
        self.desiredFreeGB = desiredFreeGB
        self.entries = entries
    }

    var requestedGainGB: Double { max(0, desiredFreeGB - baselineFreeGB) }
    var readyEntries: [CleanupPlanEntry] { entries.filter { $0.preview.canExecute } }
    var blockedEntries: [CleanupPlanEntry] { entries.filter { !$0.preview.canExecute } }
    var estimatedKB: Int64 {
        readyEntries.reduce(0) { $0 + max(0, $1.preview.estimatedKB) }
    }
    var estimatedGB: Double { Double(estimatedKB) / 1_048_576 }
    var earliestApprovalExpiry: Date? {
        let expiries = readyEntries.compactMap(\.preview.approvalExpiresAt)
        guard expiries.count == readyEntries.count else { return nil }
        return expiries.min()
    }
    var canExecute: Bool { canExecute(at: Date()) }

    func canExecute(at date: Date) -> Bool {
        !readyEntries.isEmpty && readyEntries.allSatisfy {
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
    let reclaimedKB: Int64
    let physicalDeltaKB: Int64
    let receipt: String
    let detail: String

    var id: String { recipeID + "\u{0}" + requestTarget }
    var succeeded: Bool { status == "complete" }
}

struct CleanupRecoveryResult {
    let baselineFreeGB: Double
    let finalFreeGB: Double
    let desiredFreeGB: Double
    let freeSpaceMeasured: Bool
    let plannedCount: Int
    let items: [CleanupRecoveryItemResult]
    let stoppedAfterFailure: Bool
    let rescanScheduled: Bool

    var actualGainGB: Double {
        freeSpaceMeasured ? max(0, finalFreeGB - baselineFreeGB) : 0
    }
    var goalMet: Bool { freeSpaceMeasured && finalFreeGB >= desiredFreeGB }
    var succeededCount: Int { items.filter(\.succeeded).count }
    var skippedCount: Int { max(0, plannedCount - items.count) }
    var failedItems: [CleanupRecoveryItemResult] { items.filter { !$0.succeeded } }
}

enum StorageRecoveryPolicy {
    static let desiredFreeGB = 20.0

    static func requiredGainGB(
        currentFreeGB: Double,
        desiredFreeGB: Double = StorageRecoveryPolicy.desiredFreeGB
    ) -> Double {
        max(0, desiredFreeGB - max(0, currentFreeGB))
    }
}
