import Foundation

struct IncidentAssessment: Equatable {
    enum Kind: Equatable {
        case noResult
        case securityDanger
        case storageCritical
        case collectionIncomplete
        case browserAutomation
        case storageDrop
        case securityAttention
        case runtimeAttention
        case clear

        var historyKey: String {
            switch self {
            case .noResult: return "no_result"
            case .securityDanger: return "security_danger"
            case .storageCritical: return "storage_critical"
            case .collectionIncomplete: return "collection_incomplete"
            case .browserAutomation: return "browser_automation"
            case .storageDrop: return "storage_drop"
            case .securityAttention: return "security_attention"
            case .runtimeAttention: return "runtime_attention"
            case .clear: return "clear"
            }
        }
    }

    let kind: Kind
    let title: String
    let detail: String
    let impact: String
    let value: String
    let symbol: String

    static func make(
        content: ScanContent,
        storageChange: StorageChangeSummary?
    ) -> IncidentAssessment {
        guard content.summary != nil || content.storage != nil else {
            return IncidentAssessment(
                kind: .noResult,
                title: "아직 판단할 검사 결과가 없습니다",
                detail: "지금 검사를 실행하면 실행 프로세스, 네트워크, 자동 실행, 보호 상태와 저장공간 변화를 함께 확인합니다.",
                impact: "검사 전에는 현재 Mac의 이상 징후나 검사 범위를 판단하지 않습니다.",
                value: "검사 필요",
                symbol: "questionmark.circle"
            )
        }

        if content.securityHasDanger {
            let first = content.securityAttentionFindings.first
            return IncidentAssessment(
                kind: .securityDanger,
                title: first?.title ?? "즉시 확인할 위험 신호가 있습니다",
                detail: first?.detail ?? "보안 진단에서 위험 등급 신호를 확인했습니다.",
                impact: "알 수 없는 상주 작업이나 외부 통신이 계속될 수 있으므로 삭제 전에 프로세스와 경로를 확인해야 합니다.",
                value: "위험",
                symbol: "exclamationmark.shield"
            )
        }

        if let storage = content.storage, storage.risk == "danger" {
            return IncidentAssessment(
                kind: .storageCritical,
                title: "저장공간이 임계 수준입니다",
                detail: String(format: "시동 볼륨에 %.1fGB가 남아 있고 사용률은 %.0f%%입니다.", storage.freeGB, storage.usePercent),
                impact: "빌드 실패, swap 증가, 앱 응답 지연과 임시파일 생성 실패가 이어질 수 있습니다.",
                value: String(format: "%.1fGB 남음", storage.freeGB),
                symbol: "internaldrive.fill"
            )
        }

        if let coverage = content.collectionCoverage, !coverage.complete {
            let labels = coverage.requiredIssues.prefix(2).map(\.label).joined(separator: ", ")
            let missing = labels.isEmpty ? "일부 필수 수집기" : labels
            return IncidentAssessment(
                kind: .collectionIncomplete,
                title: "안전 여부 판단을 보류했습니다",
                detail: "\(missing)을 완료하지 못했습니다. 비어 있는 결과를 정상으로 해석하지 않습니다.",
                impact: "확인하지 못한 영역의 프로세스, 연결 또는 자동 실행 항목이 결과에서 빠졌을 수 있습니다.",
                value: coverage.coverageText,
                symbol: "questionmark.shield"
            )
        }

        if content.collectionCoverage == nil {
            return IncidentAssessment(
                kind: .collectionIncomplete,
                title: "검사 범위를 확인할 수 없습니다",
                detail: "이전 형식의 결과에는 수집 성공 여부가 기록되지 않았습니다. 새 검사 전에는 정상 판정을 사용하지 않습니다.",
                impact: "결과가 비어 있어도 실제 항목이 없었던 것인지 수집에 실패한 것인지 구분할 수 없습니다.",
                value: "판단 보류",
                symbol: "questionmark.shield"
            )
        }

        if let browser = content.storage?.browserAutomation, browser.needsAttention {
            return IncidentAssessment(
                kind: .browserAutomation,
                title: browser.verdict == "orphaned"
                    ? "소유 작업을 찾지 못한 자동화가 있습니다"
                    : "기본 Chrome과 자동화가 충돌할 수 있습니다",
                detail: browser.note,
                impact: "일반 Chrome이 열리지 않거나 임시 프로필과 code-sign clone이 계속 남을 수 있습니다.",
                value: "\(browser.rootCount)개 루트",
                symbol: "rectangle.on.rectangle"
            )
        }

        if let change = storageChange, change.consumedGB >= 8 {
            let cause = change.primaryCause.map { " 가장 크게 함께 증가한 후보는 \($0.label)입니다." } ?? ""
            return IncidentAssessment(
                kind: .storageDrop,
                title: "저장공간이 빠르게 줄었습니다",
                detail: String(format: "직전 검사보다 %.1fGB 감소했습니다.%@", change.consumedGB, cause),
                impact: "같은 생성원이 실행 중이면 정리 뒤에도 공간이 다시 줄어들 수 있습니다.",
                value: String(format: "-%.1fGB", change.consumedGB),
                symbol: "arrow.down.right.circle"
            )
        }

        if let first = content.securityAttentionFindings.first {
            return IncidentAssessment(
                kind: .securityAttention,
                title: first.title,
                detail: first.detail,
                impact: "현재 정보만으로 악성 여부를 확정하지 않으며 실행 경로와 설치 맥락을 먼저 대조해야 합니다.",
                value: "확인 필요",
                symbol: "info.circle"
            )
        }

        if let signal = content.storage?.attentionRuntimeSignals.first {
            return IncidentAssessment(
                kind: .runtimeAttention,
                title: "개발 작업이 백그라운드에서 계속 실행 중입니다",
                detail: "\(signal.label): \(signal.note.isEmpty ? signal.action : signal.note)",
                impact: "캐시, Simulator 데이터 또는 임시 브라우저 파일이 다시 생성될 수 있습니다.",
                value: signal.countText,
                symbol: "hammer"
            )
        }

        let coverage = content.collectionCoverage
        return IncidentAssessment(
            kind: .clear,
            title: "현재 뚜렷한 이상 징후가 없습니다",
            detail: "필수 수집기 \(coverage?.completedRequiredCount ?? 0)/\(coverage?.requiredCount ?? 0)개가 완료됐고 위험·확인 신호가 없습니다.",
            impact: "이 판단은 표시된 검사 시점과 수집 범위 안에서만 유효합니다.",
            value: "범위 내 정상",
            symbol: "checkmark.circle"
        )
    }
}
