import Foundation

private enum PathReconnectValidation {
    static func identifier(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{48}$", options: .regularExpression) != nil
    }

    static func path(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && !value.contains("\0")
            && !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}

struct PathReconnectPlan: Decodable {
    let schemaVersion: Int
    let planID, originalPath, targetPath, targetKind: String
    let bytes: Int64?
    let sha256: String?
    let createdAt, expiresAt: Double
    let warnings: [String]
    let impact: String

    func matches(original: URL, target: URL) -> Bool {
        schemaVersion == 1 && PathReconnectValidation.identifier(planID)
            && originalPath == original.path && targetPath == target.path && originalPath != targetPath
            && PathReconnectValidation.path(originalPath) && PathReconnectValidation.path(targetPath)
            && ["file", "directory"].contains(targetKind)
            && createdAt.isFinite && expiresAt.isFinite && expiresAt > createdAt
            && (bytes == nil || bytes! >= 0)
            && (sha256 == nil || sha256!.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
    }
}

struct PathReconnectConnection: Decodable, Identifiable {
    let schemaVersion: Int
    let connectionID, status, originalPath, targetPath, targetKind, receiptPath: String
    let warnings: [String]
    let reason: String

    var id: String { connectionID }
    var valid: Bool {
        schemaVersion == 1 && PathReconnectValidation.identifier(connectionID)
            && PathReconnectValidation.path(originalPath) && PathReconnectValidation.path(targetPath)
            && PathReconnectValidation.path(receiptPath) && originalPath != targetPath
            && ["file", "directory"].contains(targetKind)
            && ["connected", "disconnected", "ssd-unavailable", "target-replaced", "conflict",
                "original-missing", "recovery-needed"].contains(status)
    }
    var canDisconnect: Bool { ["connected", "ssd-unavailable", "target-replaced"].contains(status) }
    var statusLabel: String {
        switch status {
        case "connected": return L10n.text("경로 연결됨 · 앱 재개 미검증")
        case "disconnected": return L10n.text("연결 해제됨")
        case "ssd-unavailable": return L10n.text("SSD 연결 확인 필요")
        case "target-replaced": return L10n.text("SSD 대상이 바뀜")
        case "conflict": return L10n.text("기존 경로 충돌")
        case "original-missing": return L10n.text("연결 경로 없음")
        default: return L10n.text("연결 복구 확인 필요")
        }
    }
    func matches(_ plan: PathReconnectPlan) -> Bool {
        valid && connectionID == plan.planID && originalPath == plan.originalPath
            && targetPath == plan.targetPath && targetKind == plan.targetKind && status == "connected"
    }
    func confirmsUndo(of connection: Self) -> Bool {
        valid && connectionID == connection.connectionID && originalPath == connection.originalPath
            && targetPath == connection.targetPath && targetKind == connection.targetKind && status == "disconnected"
    }
}

struct PathReconnectCandidate: Decodable, Identifiable {
    let originalPath, targetPath, receiptPath: String
    let bytes: Int64?
    var id: String { originalPath }
    var valid: Bool {
        PathReconnectValidation.path(originalPath) && PathReconnectValidation.path(targetPath)
            && PathReconnectValidation.path(receiptPath) && (bytes == nil || bytes! >= 0)
    }
}

struct PathReconnectInventory: Decodable {
    let schemaVersion: Int
    let connections: [PathReconnectConnection]
    let candidates: [PathReconnectCandidate]
    let warnings: [String]
    var valid: Bool {
        schemaVersion == 1 && connections.count <= 100 && candidates.count <= 500
            && connections.allSatisfy(\.valid) && candidates.allSatisfy(\.valid)
            && Set(connections.map(\.id)).count == connections.count
            && Set(candidates.map(\.id)).count == candidates.count
    }
}
