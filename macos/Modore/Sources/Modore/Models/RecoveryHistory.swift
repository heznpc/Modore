import Foundation

/// Display-only journal. Deliberately contains no approval token and cannot
/// reconstruct an executable CleanupRecoveryPlan after a restart.
struct RecoveryHistory: Codable, Identifiable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case reviewed, approved, running, finished, interrupted, cancelled

        var title: String {
            switch self {
            case .reviewed: return "미승인 · 다시 측정 필요"
            case .approved: return "승인됨 · 실행 준비"
            case .running: return "실행 중"
            case .finished: return "실행 결과 기록됨"
            case .interrupted: return "중단 · 결과 확인 필요"
            case .cancelled: return "미실행 · 검토 취소"
            }
        }
    }

    struct Entry: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let recipeID: String
        let label: String
        let targets: [String]
        let estimatedBytes: Int64?
        let ready: Bool
        let previewStatus: String
    }

    struct Item: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let status: String
        let reclaimedBytes: Int64?
        let physicalDeltaBytes: Int64?
        let receipt: String
        let detail: String

        init(_ result: CleanupRecoveryItemResult) {
            id = result.id
            status = result.status
            reclaimedBytes = result.reclaimedBytes
            physicalDeltaBytes = result.physicalDeltaBytes
            receipt = result.receipt
            detail = result.detail
        }
    }

    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let baselineFreeBytes: Int64
    let requestedGainBytes: Int64
    let entries: [Entry]
    var phase: Phase = .reviewed
    var approvedAt: Date?
    var activeEntryID: String?
    var items: [Item] = []
    var finalFreeBytes: Int64?
    var stoppedAfterFailure = false
    var detail = ""

    init(plan: CleanupRecoveryPlan) {
        id = plan.id
        createdAt = plan.createdAt
        updatedAt = plan.createdAt
        baselineFreeBytes = plan.baselineFreeBytes
        requestedGainBytes = plan.requestedGainBytes
        entries = plan.entries.map {
            Entry(id: $0.id, recipeID: $0.preview.recipeID, label: $0.preview.label,
                  targets: $0.preview.targets, estimatedBytes: $0.preview.estimatedBytes,
                  ready: $0.preview.canExecute, previewStatus: $0.preview.statusText)
        }
    }

    var desiredFreeBytes: Int64? { StorageBytes.adding(baselineFreeBytes, requestedGainBytes) }
    var actualChangeBytes: Int64? { finalFreeBytes.map { $0 - baselineFreeBytes } }
    var goalMet: Bool {
        guard phase == .finished, let finalFreeBytes, let desiredFreeBytes else { return false }
        return finalFreeBytes >= desiredFreeBytes
    }

    var afterRestart: Self {
        var record = self
        if phase == .approved || phase == .running {
            record.phase = .interrupted
            record.finalFreeBytes = nil
            record.detail = "최종 결과가 기록되기 전에 앱이 종료되었습니다. 남은 항목은 자동 실행하지 않습니다."
        }
        return record
    }
}
