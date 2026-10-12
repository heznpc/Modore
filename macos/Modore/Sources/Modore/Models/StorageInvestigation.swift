import Foundation

enum StorageJudgment: String, CaseIterable, Identifiable {
    case ready, inUse, uncertain, preserve
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ready: return "정리 가능"
        case .inUse: return "사용 중"
        case .uncertain: return "확인 부족"
        case .preserve: return "보존 검토"
        }
    }
}

enum StorageResultFilter: String, CaseIterable, Identifiable {
    case all = "전체", development = "개발", applications = "앱", simulators = "시뮬레이터"
    var id: String { rawValue }
    func includes(_ item: StorageItem) -> Bool {
        switch self {
        case .all: return true
        case .applications: return item.kind == "application"
        case .simulators: return item.kind.hasPrefix("simulator_")
        case .development: return item.kind != "application" && !item.kind.hasPrefix("simulator_")
        }
    }
}

enum StorageInvestigationIssue: String {
    case notInvestigated, timedOut, access, usage, validation
    var title: String {
        switch self {
        case .notInvestigated: return "아직 조사하지 않았습니다"
        case .timedOut: return "시간 안에 조사를 마치지 못했습니다"
        case .access: return "폴더 접근을 확인해야 합니다"
        case .usage: return "사용 상태를 확인하지 못했습니다"
        case .validation: return "대상 검증을 마치지 못했습니다"
        }
    }
    var action: String {
        switch self {
        case .notInvestigated: return "이 항목 조사"
        case .timedOut: return "이 항목만 다시 조사"
        case .access: return "접근 설정 열기"
        case .usage: return "사용 상태 다시 확인"
        case .validation: return "이 항목 다시 조사"
        }
    }
}

/// Durable-for-this-session evidence, deliberately without an execution token.
/// A new approval preview is always required after the person selects items.
struct StorageInvestigation {
    let date: Date
    let judgment: StorageJudgment
    let issue: StorageInvestigationIssue?
    let bytes: Int64?
    let reason: String
    let usage: String
    let regeneration: String
    let impact: String
    let targets: [String]
    let preserved: [String]

    static func pathIsMissing(_ item: StorageItem) -> Bool {
        guard item.path.hasPrefix("/") else { return false }
        do { _ = try FileManager.default.attributesOfItem(atPath: item.path); return false }
        catch let error as NSError {
            // Permission denial is unknown, never evidence that a path is gone.
            return error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        }
    }

    static func evidence(item: StorageItem, result: CapturedProcessResult?, at date: Date = Date(), pathMissing: Bool = false) -> Self {
        if pathMissing {
            return Self(date: date, judgment: .preserve, issue: nil, bytes: 0,
                reason: "현재 경로가 없습니다. 이미 정리되었거나 이동되었을 수 있습니다.",
                usage: "현재 경로 없음 · 조사 대상에서 제외", regeneration: "경로가 다시 생기면 새로 조사하세요",
                impact: "", targets: [], preserved: [])
        }
        let preview = result.flatMap { CleanupPreview(protocolText: $0.output) }
        let valid = result?.endState == .exited && result?.outputTruncated == false
            && preview?.operation == "preview" && preview?.recipeID == item.cleanupID
        guard valid, let preview else {
            let issue: StorageInvestigationIssue = result == nil || result?.endState == .timedOut ? .timedOut : .validation
            return Self(date: date, judgment: .uncertain, issue: issue, bytes: nil,
                reason: issue.title, usage: "현재 사용 상태 미확인", regeneration: "재생성 근거 미검증", impact: "",
                targets: [], preserved: [])
        }
        let reason = preview.blockedReason.isEmpty ? preview.statusText : preview.blockedReason
        let lower = reason.lowercased()
        let usageUnknown = preview.runningProcesses.contains("미확인")
            || (lower.contains("사용") && (lower.contains("미확인") || lower.contains("확인하지 못")))
        let issue: StorageInvestigationIssue? = {
            if preview.canExecute && result?.succeeded == true { return nil }
            if preview.status == "empty" { return nil }
            if usageUnknown { return .usage }
            if !preview.runningProcesses.isEmpty { return nil }
            if lower.contains("permission") || lower.contains("접근") || lower.contains("권한") { return .access }
            if lower.contains("timeout") || lower.contains("시간") { return .timedOut }
            if lower.contains("lsof") || lower.contains("프로세스") || lower.contains("사용") { return .usage }
            return .validation
        }()
        let judgment: StorageJudgment
        if !preview.runningProcesses.isEmpty && !usageUnknown { judgment = .inUse }
        else if preview.canExecute && preview.estimateMeasured && preview.estimatedBytes != nil && result?.succeeded == true {
            judgment = item.cleanupTier == nil ? .preserve : .ready
        } else if preview.status == "empty" { judgment = .preserve }
        else { judgment = .uncertain }
        let usage = !preview.usageEvidence.isEmpty ? preview.usageEvidence
            : (!preview.runningProcesses.isEmpty ? preview.runningProcesses
                : (preview.canExecute && result?.succeeded == true ? "정리 규칙의 사용 검사 통과 · 미사용 확정 아님" : "현재 사용 상태 미확인"))
        let regeneration = preview.regenerationEvidence
        let impact = [preview.summary, preview.warning, preview.processNote].filter { !$0.isEmpty }.joined(separator: " · ")
        return Self(date: date, judgment: judgment, issue: issue,
            bytes: preview.estimateMeasured ? preview.estimatedBytes : nil,
            reason: reason, usage: usage,
            regeneration: regeneration.isEmpty ? "재생성 근거 미검증 · 내용을 확인하세요" : regeneration,
            impact: impact, targets: preview.targets, preserved: preview.reviewResidue + preview.sharedResidue)
    }

    static func inventory(_ storage: StorageSnapshot) -> [StorageItem] {
        var seen = Set<String>()
        var executions = Set<String>()
        let devices = storage.simulatorDevices.compactMap { device in
            StorageItem(json: ["kind": "simulator_device", "label": device.name,
                "path": device.path, "sizeGB": device.sizeGB, "measureStatus": device.measureStatus,
                "note": "기기 데이터와 설치 앱은 재생성을 보장할 수 없습니다. 보존할 기기를 확인하세요."])
        }
        return (storage.recoveryCandidates + storage.reviewCandidates + storage.developerToolchains
            + storage.applications + devices).filter {
                let pathIsNew = seen.insert($0.path.isEmpty ? SpaceGoalSelection.key($0) : $0.path).inserted
                guard pathIsNew else { return false }
                if $0.hasSupportedCleanupRecipe && !CleanupExecutionRequest.isRequired(for: $0.cleanupID) {
                    return executions.insert($0.cleanupID).inserted
                }
                return true
            }.sorted { $0.sizeGB == $1.sizeGB ? $0.label < $1.label : $0.sizeGB > $1.sizeGB }
    }

    static func judgment(for item: StorageItem, evidence: Self?) -> StorageJudgment {
        evidence?.judgment ?? (item.hasSupportedCleanupRecipe ? .uncertain : .preserve)
    }
}

extension StorageItem {
    var investigationKey: String { SpaceGoalSelection.key(self) }
}
