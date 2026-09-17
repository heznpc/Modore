import Foundation

struct CleanupPreview: Identifiable, Sendable {
    let id = UUID()
    let operation: String
    let status: String
    let actionMode: String
    let recipeID: String
    let label: String
    let estimatedKB: Int64
    let estimateMeasured: Bool
    let estimatedBytes: Int64?
    let reclaimedBytes: Int64?
    let physicalDeltaBytes: Int64?
    let warning: String
    let summary: String
    let avoidWhen: String
    let processNote: String
    let blockedReason: String
    let runningProcesses: String
    let approvalToken: String
    let approvalExpiresAt: Date?
    let targets: [String]
    let stagedRemainders: [String]
    let sharedResidue: [String]
    let reviewResidue: [String]
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
        estimateMeasured = payload.estimateMeasured
        estimatedBytes = payload.estimatedBytes
        reclaimedBytes = payload.reclaimedBytes
        physicalDeltaBytes = payload.physicalDeltaBytes
        warning = payload.warning
        summary = payload.summary
        avoidWhen = payload.avoidWhen
        processNote = payload.processNote
        blockedReason = payload.blockedReason
        runningProcesses = payload.runningProcesses
        approvalToken = payload.approvalToken
        approvalExpiresAt = payload.approvalExpiresEpoch > 0
            ? Date(timeIntervalSince1970: TimeInterval(payload.approvalExpiresEpoch))
            : nil
        targets = payload.targets
        stagedRemainders = payload.stagedRemainders
        sharedResidue = payload.sharedResidue
        reviewResidue = payload.reviewResidue
        receipt = payload.receipt
        trashRun = payload.trashRun
    }

    /// A failed read is an unavailable row, never an execution capability.
    static func unavailable(recipeID: String, label: String, reason: String) -> CleanupPreview {
        func field(_ value: String) -> String {
            value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        return CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tunavailable
        recipeId\t\(field(recipeID))
        label\t\(field(label))
        estimateMeasured\tfalse
        blockedReason\t\(field(reason))
        """)!
    }

    var canExecute: Bool {
        status == "ready"
            && approvalToken.utf8.count == 64
            && approvalToken.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }
    var isComplete: Bool { status == "complete" }

    func approvalIsFresh(
        at date: Date = Date(),
        minimumRemaining: TimeInterval = 0
    ) -> Bool {
        guard canExecute, let approvalExpiresAt else { return false }
        return approvalExpiresAt.timeIntervalSince(date) >= minimumRemaining
    }

    var recoveryPathMessages: [String] {
        var messages = stagedRemainders.map { L10n.format("격리 보존 경로: %@", String(describing: $0)) }
        if !trashRun.isEmpty {
            messages.append(L10n.format("휴지통 경로: %@", String(describing: trashRun)))
        }
        if !receipt.isEmpty {
            messages.append(L10n.format("영수증: %@", String(describing: receipt)))
        }
        return messages
    }

    var failureMessage: String {
        let summary = blockedReason.isEmpty
            ? L10n.text("일부 항목을 정리하지 못했습니다. 복구 경로와 실행 로그를 확인하세요.")
            : blockedReason
        return ([summary] + recoveryPathMessages).joined(separator: "\n")
    }

    var estimatedText: String {
        estimateMeasured ? StorageBytes.text(estimatedBytes) : L10n.text("측정 보류")
    }
    var reclaimedText: String { StorageBytes.text(reclaimedBytes) }
    var physicalDeltaText: String { StorageBytes.changeText(physicalDeltaBytes) }

    var statusText: String {
        switch status {
        case "ready": return L10n.text("실행 준비됨")
        case "blocked": return runningProcesses.isEmpty ? L10n.text("이 항목은 확인이 필요합니다") : L10n.text("사용 중인 대상입니다")
        case "unavailable": return L10n.text("이번 확인에서 제외됨")
        case "empty": return L10n.text("이미 정리되어 있습니다")
        case "complete": return L10n.text("정리 완료")
        case "partial": return L10n.text("일부 항목만 정리됨")
        default: return status
        }
    }

}

private struct ParsedProtocolLines {
    let values: [String: String]
    let targets: [String]
    let stagedRemainders: [String]
    let sharedResidue: [String]
    let reviewResidue: [String]
}

private struct CleanupProtocolPayload {
    let operation: String
    let status: String
    let actionMode: String
    let recipeID: String
    let label: String
    let estimatedKB: Int64
    let estimateMeasured: Bool
    let estimatedBytes: Int64?
    let reclaimedBytes: Int64?
    let physicalDeltaBytes: Int64?
    let warning: String
    let summary: String
    let avoidWhen: String
    let processNote: String
    let blockedReason: String
    let runningProcesses: String
    let approvalToken: String
    let approvalExpiresEpoch: Int64
    let targets: [String]
    let stagedRemainders: [String]
    let sharedResidue: [String]
    let reviewResidue: [String]
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
            estimateMeasured: estimateMeasured(values, status: status),
            estimatedBytes: byteValue(values, key: "estimated"),
            reclaimedBytes: byteValue(values, key: "reclaimed"),
            physicalDeltaBytes: byteValue(values, key: "physicalDelta", signed: true),
            warning: values["warning"] ?? "",
            // 구버전 런타임 미러에는 두 키가 없다. 설명이 비면 UI가 해당 줄을 숨긴다.
            summary: values["description"] ?? "",
            avoidWhen: values["avoidWhen"] ?? "",
            processNote: values["processNote"] ?? "",
            blockedReason: values["blockedReason"] ?? "",
            runningProcesses: values["runningProcesses"] ?? "",
            approvalToken: values["approvalToken"] ?? "",
            approvalExpiresEpoch: integer(values["approvalExpiresEpoch"]),
            targets: parsed.targets,
            stagedRemainders: parsed.stagedRemainders,
            sharedResidue: parsed.sharedResidue,
            reviewResidue: parsed.reviewResidue,
            receipt: values["receipt"] ?? "",
            trashRun: values["trashRun"] ?? ""
        )
    }

    private static func parseLines(
        _ text: String
    ) -> ParsedProtocolLines {
        var values: [String: String] = [:]
        var targets: [String] = []
        var stagedRemainders: [String] = []
        var sharedResidue: [String] = []
        var reviewResidue: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1])
            if key == "target" {
                targets.append(value)
            } else if key == "stagedRemainder" {
                stagedRemainders.append(value)
            } else if key == "sharedResidue" {
                sharedResidue.append(value)
            } else if key == "reviewResidue" {
                reviewResidue.append(value)
            } else {
                values[key] = value
            }
        }
        return ParsedProtocolLines(
            values: values,
            targets: targets,
            stagedRemainders: stagedRemainders,
            sharedResidue: sharedResidue,
            reviewResidue: reviewResidue
        )
    }

    private static func integer(_ value: String?) -> Int64 {
        Int64(value ?? "0") ?? 0
    }

    private static func byteValue(_ values: [String: String], key: String, signed: Bool = false) -> Int64? {
        let value: Int64?
        if values["accountingVersion"] == "2" {
            // An explicit empty/invalid measurement must not fall back to an
            // old placeholder, nor may a missing value become a measured zero.
            value = byteInteger(values[key + "Bytes"])
        } else if values["accountingVersion"] == nil || values["accountingVersion"] == "1" {
            let legacyValue = byteInteger(values[key + "KB"])
            if signed && legacyValue == 0 { return nil }
            value = StorageBytes.fromKiB(legacyValue)
        } else {
            value = nil
        }
        guard let value, signed || value >= 0 else { return nil }
        return value
    }

    private static func byteInteger(_ text: String?) -> Int64? {
        guard let text, !text.isEmpty, text.utf8.count <= 20 else { return nil }
        let digits = text.hasPrefix("-") ? text.dropFirst() : text[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(text)
    }

    // 구버전 런타임 미러에는 estimateMeasured 키가 없다. 그 경우 차단 상태의
    // estimatedKB 0은 측정값이 아니라 자리 표시 값이므로 미측정으로 해석한다.
    private static func estimateMeasured(
        _ values: [String: String],
        status: String
    ) -> Bool {
        if let raw = values["estimateMeasured"] {
            return raw == "true"
        }
        return !(status == "blocked" && integer(values["estimatedKB"]) == 0)
    }
}
