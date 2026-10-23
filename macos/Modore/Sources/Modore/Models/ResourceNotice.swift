import Foundation

enum HealthResourceFocus: String, Equatable, Sendable {
    case memory, cpu

    var title: String { L10n.text(self == .memory ? "RAM 사용량 검토" : "CPU 부하 검토") }

    func sorted(_ processes: [HealthProcess]) -> [HealthProcess] {
        processes.sorted { left, right in
            let lhs = value(left), rhs = value(right)
            if lhs != rhs { return (lhs ?? -1) > (rhs ?? -1) }
            return left.pid < right.pid
        }
    }

    private func value(_ process: HealthProcess) -> Double? {
        switch self {
        case .memory: return (process.physicalFootprintBytes ?? process.residentBytes).map(Double.init)
        case .cpu: return process.cpuMeasured == false ? nil : process.cpu
        }
    }
}

/// Notification copy has its own bounded presentation. Journals keep the full
/// diagnostics; a banner identifies the relevant resource and the next action.
struct ResourceNotice {
    let title: String
    let body: String
    let route: String

    static func health(_ snapshot: HealthSnapshot, notifyStorage: Bool,
                       toolAccumulation: MemoryToolAccumulation? = nil) -> Self {
        if notifyStorage {
            return Self(title: L10n.format("공간 부족 · %@ 남음", HealthSnapshot.bytes(snapshot.freeBytes)),
                        body: L10n.text("눌러서 정리할 항목과 예상 확보량을 검토하세요."), route: "storage")
        }
        if (snapshot.memoryPressure ?? 0) >= 2 {
            if let tools = toolAccumulation {
                return Self(title: L10n.format("RAM 압박 · 도구 프로세스 %@개 실행 중", String(tools.processCount)),
                            body: L10n.format("여러 시점에 시작된 도구 · %@\n눌러서 실행 앱과 관련 작업을 확인하세요.",
                                              HealthSnapshot.bytes(Int64(clamping: tools.bytes))), route: "memory")
            }
            let top = HealthResourceFocus.memory.sorted(snapshot.processes).first { $0.physicalFootprintBytes != nil || $0.residentBytes != nil }
            let evidence = top.map {
                L10n.format("측정된 메모리 상위: %@ · %@", String($0.name.prefix(24)),
                    HealthSnapshot.bytes(($0.physicalFootprintBytes ?? $0.residentBytes).map { Int64(clamping: $0) }))
            } ?? L10n.text("앱별 메모리 사용량은 아직 확인하지 못했습니다.")
            return Self(title: L10n.text("RAM 압박 · 사용 앱을 확인하세요"),
                        body: evidence + "\n" + L10n.text("눌러서 사용량을 확인하고, 필요 없는 앱을 닫으세요."), route: "memory")
        }
        if snapshot.cpuElevated || snapshot.cpuBurst == true {
            let top = snapshot.cpuAvailable ? HealthResourceFocus.cpu.sorted(snapshot.processes).first { $0.cpuMeasured != false } : nil
            let evidence = top.map { L10n.format("측정된 CPU 상위: %@ · %@%%", String($0.name.prefix(24)), String(Int($0.cpu))) }
                ?? L10n.text("프로세스별 CPU 사용량은 아직 확인하지 못했습니다.")
            return Self(title: L10n.text(snapshot.cpuElevated ? "CPU 부하 지속 · 실행 작업을 확인하세요" : "CPU 순간 부하 · 실행 작업을 확인하세요"),
                        body: evidence + "\n" + L10n.text("눌러서 실행 작업과 중단·재시작 방법을 확인하세요."), route: "cpu")
        }
        return Self(title: L10n.text(snapshot.complete ? "관찰된 부하가 낮아졌습니다" : "일부 상태를 확인하지 못했습니다"),
                    body: L10n.text("눌러서 현재 상태와 관찰 기록을 확인하세요."), route: "health")
    }

    static func automaticRecovery(_ report: AutomaticCacheReport) -> Self {
        guard report.finished else {
            return Self(title: L10n.text("자동 정리가 중단됐습니다"),
                        body: L10n.text("눌러서 처리 기록과 남은 정리 항목을 확인하세요."), route: "storage-result")
        }
        guard let after = report.after else {
            return Self(title: L10n.text("정리 후 여유 공간을 확인하지 못했습니다"),
                        body: L10n.text("눌러서 현재 공간과 처리 기록을 다시 확인하세요."), route: "storage-result")
        }
        let remaining = AutomaticCachePolicy.remainingBytes(after: after) ?? 0
        let title = L10n.format(remaining > 0 ? "여유 %@ · 추가 확보 필요" : "여유 %@ · 확보 목표 도달", HealthSnapshot.bytes(after))
        let action = remaining > 0
            ? L10n.format("%@ 목표까지 %@ 부족. 눌러서 정리할 항목을 선택하세요.", HealthSnapshot.bytes(AutomaticCachePolicy.target), HealthSnapshot.bytes(remaining))
            : L10n.text("추가 정리는 필요하지 않습니다. 누르면 처리 기록을 볼 수 있습니다.")
        // The free-space delta also includes other writers; never label it reclaimed.
        let result = report.receipts.isEmpty ? L10n.text("이번 실행에서 확인된 정리 기록 없음.")
            : L10n.format("캐시 처리 기록 %@건.", String(report.receipts.count))
        return Self(title: title, body: action + "\n" + result, route: "storage-result")
    }
}
