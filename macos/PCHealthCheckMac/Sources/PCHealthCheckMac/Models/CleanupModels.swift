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
    let approvalToken: String
    let targets: [String]
    let stagedRemainders: [String]
    let receipt: String
    let trashRun: String

    init?(protocolText: String) {
        guard let payload = CleanupProtocolPayload.parse(protocolText) else { return nil }
        operation = payload.operation
        status = payload.status
        actionMode = payload.actionMode
        recipeID = payload.recipeID
        label = payload.label
        estimatedKB = payload.estimatedKB
        reclaimedKB = payload.reclaimedKB
        physicalDeltaKB = payload.physicalDeltaKB
        warning = payload.warning
        processNote = payload.processNote
        blockedReason = payload.blockedReason
        runningProcesses = payload.runningProcesses
        approvalToken = payload.approvalToken
        targets = payload.targets
        stagedRemainders = payload.stagedRemainders
        receipt = payload.receipt
        trashRun = payload.trashRun
    }

    var canExecute: Bool {
        status == "ready"
            && approvalToken.utf8.count == 64
            && approvalToken.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }
    var isComplete: Bool { status == "complete" }

    var recoveryPathMessages: [String] {
        var messages = stagedRemainders.map { "격리 보존 경로: \($0)" }
        if !trashRun.isEmpty {
            messages.append("휴지통 경로: \(trashRun)")
        }
        if !receipt.isEmpty {
            messages.append("영수증: \(receipt)")
        }
        return messages
    }

    var failureMessage: String {
        let summary = blockedReason.isEmpty
            ? "일부 항목을 정리하지 못했습니다. 복구 경로와 실행 로그를 확인하세요."
            : blockedReason
        return ([summary] + recoveryPathMessages).joined(separator: "\n")
    }

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

private struct CleanupProtocolPayload {
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
    let approvalToken: String
    let targets: [String]
    let stagedRemainders: [String]
    let receipt: String
    let trashRun: String

    static func parse(_ text: String) -> CleanupProtocolPayload? {
        let parsed = parseLines(text)
        let values = parsed.values
        guard values["version"] == "1",
              let recipeID = values["recipeId"], !recipeID.isEmpty,
              let status = values["status"], !status.isEmpty else {
            return nil
        }
        return CleanupProtocolPayload(
            operation: values["operation"] ?? "preview",
            status: status,
            actionMode: values["actionMode"] ?? "remove",
            recipeID: recipeID,
            label: values["label"] ?? recipeID,
            estimatedKB: integer(values["estimatedKB"]),
            reclaimedKB: integer(values["reclaimedKB"]),
            physicalDeltaKB: integer(values["physicalDeltaKB"]),
            warning: values["warning"] ?? "",
            processNote: values["processNote"] ?? "",
            blockedReason: values["blockedReason"] ?? "",
            runningProcesses: values["runningProcesses"] ?? "",
            approvalToken: values["approvalToken"] ?? "",
            targets: parsed.targets,
            stagedRemainders: parsed.stagedRemainders,
            receipt: values["receipt"] ?? "",
            trashRun: values["trashRun"] ?? ""
        )
    }

    private static func parseLines(
        _ text: String
    ) -> (values: [String: String], targets: [String], stagedRemainders: [String]) {
        var values: [String: String] = [:]
        var targets: [String] = []
        var stagedRemainders: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1])
            if key == "target" {
                targets.append(value)
            } else if key == "stagedRemainder" {
                stagedRemainders.append(value)
            } else {
                values[key] = value
            }
        }
        return (values, targets, stagedRemainders)
    }

    private static func integer(_ value: String?) -> Int64 {
        Int64(value ?? "0") ?? 0
    }
}
