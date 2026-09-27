import Foundation

struct BackupReclaimRow: Decodable, Identifiable {
    let id, path, status, reason: String
    let bytes: Int64?
    var selectable: Bool { status == "identical" && (bytes ?? -1) >= 0 }
    var statusLabel: String {
        switch status {
        case "identical": return L10n.text("내용 일치 · 선택 가능")
        case "protected": return L10n.text("계속 사용 · 보호")
        case "different": return L10n.text("내용 다름")
        case "missing": return L10n.text("대응 사본 없음")
        case "metadata": return L10n.text("복원 속성 다름")
        default: return L10n.text("미검증")
        }
    }
}

struct BackupReclaimPlan: Decodable {
    let schemaVersion: Int
    let planID, localRoot, backupRoot: String
    let createdAt, expiresAt: Double
    let complete, processCheck: Bool
    let identicalBytes: Int64
    let rows: [BackupReclaimRow]
    let warnings: [String]
    let coverage: String

    func matches(local: URL, backup: URL) -> Bool {
        schemaVersion == 1 && planID.range(of: "^[a-f0-9]{48}$", options: .regularExpression) != nil
            && localRoot == local.path && backupRoot == backup.path
            && expiresAt > createdAt && rows.count <= 5_000 && identicalBytes >= 0
            && Set(rows.map(\.id)).count == rows.count
            && rows.allSatisfy {
                $0.id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
                    && !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..")
                    && ["identical", "protected", "different", "missing", "metadata", "unverified"].contains($0.status)
            }
    }
}

struct BackupReclaimReceipt: Decodable {
    struct Item: Decodable, Identifiable {
        let id, path, status: String
        let reason: String?
        let bytes: Int64
    }
    let schemaVersion: Int
    let planID, localRoot, backupRoot, status, receiptPath, journalPath: String
    let deletedBytes: Int64
    let freeBytesBefore: Int64
    let freeBytesAfter: Int64?
    let items: [Item]

    func matches(_ plan: BackupReclaimPlan, selected: Set<String>) -> Bool {
        schemaVersion == 1 && planID == plan.planID && localRoot == plan.localRoot
            && backupRoot == plan.backupRoot && ["finished", "partial"].contains(status)
            && Set(items.map(\.id)) == selected && items.count == selected.count
            && deletedBytes >= 0 && items.allSatisfy { ["deleted", "blocked"].contains($0.status) && $0.bytes >= 0 }
            && items.filter { $0.status == "deleted" }.reduce(Int64(0), { $0 + $1.bytes }) == deletedBytes
    }
}
