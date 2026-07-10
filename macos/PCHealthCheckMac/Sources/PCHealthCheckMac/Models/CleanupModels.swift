import Foundation

struct CleanupPreview: Identifiable {
    let id = UUID()
    let operation: String
    let status: String
    let actionMode: String
    let recipeID: String
    let label: String
    let estimatedKB: Int64
    let reclaimedKB: Int64
    let physicalDeltaKB: Int64
    let warning: String
    let processNote: String
    let blockedReason: String
    let runningProcesses: String
    let targets: [String]
    let receipt: String
    let trashRun: String

    init?(protocolText: String) {
        var values: [String: String] = [:]
        var targets: [String] = []
        for rawLine in protocolText.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1])
            if key == "target" {
                targets.append(value)
            } else {
                values[key] = value
            }
        }
        guard values["version"] == "1",
              let recipeID = values["recipeId"], !recipeID.isEmpty,
              let status = values["status"], !status.isEmpty else {
            return nil
        }
        operation = values["operation"] ?? "preview"
        self.status = status
        actionMode = values["actionMode"] ?? "remove"
        self.recipeID = recipeID
        label = values["label"] ?? recipeID
        estimatedKB = Int64(values["estimatedKB"] ?? "0") ?? 0
        reclaimedKB = Int64(values["reclaimedKB"] ?? "0") ?? 0
        physicalDeltaKB = Int64(values["physicalDeltaKB"] ?? "0") ?? 0
        warning = values["warning"] ?? ""
        processNote = values["processNote"] ?? ""
        blockedReason = values["blockedReason"] ?? ""
        runningProcesses = values["runningProcesses"] ?? ""
        self.targets = targets
        receipt = values["receipt"] ?? ""
        trashRun = values["trashRun"] ?? ""
    }

    var canExecute: Bool { status == "ready" }
    var isComplete: Bool { status == "complete" }

    var estimatedText: String { Self.sizeText(estimatedKB) }
    var reclaimedText: String { Self.sizeText(reclaimedKB) }
    var physicalDeltaText: String { Self.sizeText(physicalDeltaKB) }

    var statusText: String {
        switch status {
        case "ready": return "실행 준비됨"
        case "blocked": return "먼저 종료할 작업이 있습니다"
        case "empty": return "이미 정리되어 있습니다"
        case "complete": return "정리 완료"
        case "partial": return "일부 항목만 정리됨"
        default: return status
        }
    }

    private static func sizeText(_ value: Int64) -> String {
        if value >= 1_048_576 {
            return String(format: "%.1fGB", Double(value) / 1_048_576)
        }
        if value >= 1_024 {
            return String(format: "%.1fMB", Double(value) / 1_024)
        }
        return "\(max(value, 0))KB"
    }
}
