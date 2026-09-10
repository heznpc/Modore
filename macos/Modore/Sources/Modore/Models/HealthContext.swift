import Darwin
import Foundation

struct HealthProcess: Codable, Equatable, Identifiable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let cpu: Double
    let residentBytes: UInt64?
    let workspace: String?
}

struct HealthSnapshot: Codable, Equatable, Sendable {
    let date: Date
    let freeBytes: Int64?
    let swapBytes: UInt64?
    let memoryPressure: Int?
    let thermalPressure: Int
    let processes: [HealthProcess]
    let cpuElevated: Bool
    var cpuAvailable = true
    var cpuBurst: Bool?
    var peakCPU: Double { processes.map(\.cpu).max() ?? 0 }

    var issues: [String] {
        var result: [String] = []
        if let freeBytes, freeBytes < 20 * 1_073_741_824 { result.append(freeBytes < 5 * 1_073_741_824 ? "저장공간 임계" : "저장공간 부족") }
        if let memoryPressure, memoryPressure >= 2 { result.append("RAM 압박") }
        if cpuBurst == true && !cpuElevated { result.append("CPU 순간 부하") }
        if cpuElevated { result.append(thermalPressure >= 1 ? "발열·CPU 부하" : "CPU 부하") }
        return result
    }
    var complete: Bool { freeBytes != nil && swapBytes != nil && memoryPressure != nil && !processes.isEmpty && cpuAvailable }
    var summary: String {
        "여유 공간 \(Self.bytes(freeBytes)) · 스왑 \(swapBytes.map { Self.bytes(Int64(clamping: $0)) } ?? "미확인") · RAM \(memoryPressure.map { $0 >= 4 ? "위험" : ($0 >= 2 ? "주의" : "정상") } ?? "미확인")"
    }
    static func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "미확인"
    }
    func change(from before: Self) -> String {
        var parts: [String] = []
        if let now = freeBytes, let old = before.freeBytes {
            parts.append("여유 공간 \(now >= old ? "+" : "−")\(Self.bytes(abs(now - old)))")
        }
        if let now = swapBytes, let old = before.swapBytes {
            parts.append("스왑 \(now >= old ? "+" : "−")\(Self.bytes(Int64(clamping: now >= old ? now - old : old - now)))")
        }
        return parts.joined(separator: " · ")
    }
    func explanation(from before: Self?) -> String {
        if let before, let free = freeBytes, let oldFree = before.freeBytes,
           let swap = swapBytes, let oldSwap = before.swapBytes, free < oldFree, swap > oldSwap + 268_435_456 {
            return "여유 공간 감소와 스왑 증가가 함께 관찰됐습니다. RAM 압박이 디스크 사용에 기여했을 가능성이 있습니다. 개별 프로세스가 만든 파일의 원인까지 확정한 것은 아닙니다."
        }
        if (memoryPressure ?? 0) >= 2 { return "macOS가 RAM 압박을 보고했습니다. 아래 메모리 사용량이 큰 앱의 작업을 먼저 확인하세요. 스왑 공간은 캐시 정리와 별개로 다시 늘 수 있습니다." }
        if let freeBytes, freeBytes < 20 * 1_073_741_824 { return "빌드와 스왑에 쓸 디스크 여유가 부족합니다. 공간 확보에서 실제 회수 가능한 항목을 확인하세요. 프로세스 순위만으로 디스크를 채운 원인을 단정하지 않습니다." }
        if cpuElevated { return "CPU 부하가 지속됐습니다. 상위 프로세스와 연결된 작업을 확인하세요. CPU 100%는 코어 하나이며 온도 자체를 측정한 값은 아닙니다." }
        return complete ? "관찰 범위에서 현재 경고 기준 아래입니다." : "일부 관찰값이 없어 정상 여부를 확정하지 못했습니다."
    }

    static func capture(sample: CPUSample, usage: [CPUProcessUsage], cpuElevated: Bool, cpuBurst: Bool = false) -> Self {
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout.size(ofValue: pressure)
        let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0
        var swap = xsw_usage()
        var swapSize = MemoryLayout.size(ofValue: swap)
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        let counters = Dictionary(sample.counters.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let memory = sample.counters.sorted { $0.residentBytes > $1.residentBytes }.prefix(5)
        var rows = Array(usage.prefix(5))
        let included = Set(rows.map(\.pid))
        rows += memory.filter { !included.contains($0.pid) }.map { counter in
            CPUProcessUsage(pid: counter.pid, name: counter.name, percent: usage.first { $0.pid == counter.pid }?.percent ?? 0)
        }
        return Self(date: Date(), freeBytes: LiveStateService.observeFreeSpace()?.value.freeBytes,
                    swapBytes: swapOK ? swap.xsu_used : nil, memoryPressure: pressureOK ? Int(pressure) : nil,
                    thermalPressure: sample.thermalPressure,
                    processes: rows.map { row in
                        HealthProcess(pid: row.pid, name: row.name, cpu: row.percent,
                                      residentBytes: counters[row.pid]?.residentBytes, workspace: workspace(pid: row.pid))
                    }, cpuElevated: cpuElevated, cpuAvailable: !usage.isEmpty, cpuBurst: cpuBurst)
    }
    private static func workspace(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty || path == "/" ? nil : path
    }
}

struct HealthIncident: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let first: HealthSnapshot
    var latest: HealthSnapshot
    var resolvedAt: Date?
    var interrupted = false
    var action: String?
    var actionBaseline: HealthSnapshot?
    var issues: [String]
    var cpuPeak: HealthSnapshot?
}

struct HealthJournal: Codable, Sendable {
    var incidents: [HealthIncident] = []
    private var healthySince: Date?

    mutating func resume() {
        // A monitoring gap is not evidence of recovery.
        for index in incidents.indices where incidents[index].resolvedAt == nil { incidents[index].interrupted = true }
        healthySince = nil
    }
    @discardableResult mutating func observe(_ snapshot: HealthSnapshot) -> Bool {
        let active = incidents.firstIndex { $0.resolvedAt == nil && !$0.interrupted }
        if !snapshot.issues.isEmpty {
            healthySince = nil
            if let active {
                let changed = !Set(snapshot.issues).isSubset(of: Set(incidents[active].issues))
                incidents[active].issues = Array(Set(incidents[active].issues + snapshot.issues)).sorted()
                if snapshot.cpuBurst == true || snapshot.cpuElevated {
                    if snapshot.peakCPU > (incidents[active].cpuPeak?.peakCPU ?? -1) { incidents[active].cpuPeak = snapshot }
                }
                incidents[active].latest = snapshot
                return changed
            }
            incidents.insert(HealthIncident(id: UUID(), first: snapshot, latest: snapshot, issues: snapshot.issues, cpuPeak: (snapshot.cpuBurst == true || snapshot.cpuElevated) ? snapshot : nil), at: 0)
            incidents = Array(incidents.prefix(40))
            return true
        }
        guard let active else { return false }
        incidents[active].latest = snapshot
        guard snapshot.complete else { healthySince = nil; return false }
        if healthySince == nil { healthySince = snapshot.date }
        if snapshot.date.timeIntervalSince(healthySince!) >= 60 {
            incidents[active].resolvedAt = snapshot.date
            healthySince = nil
            return true
        }
        return false
    }
    mutating func markAction(_ label: String, snapshot: HealthSnapshot?) {
        guard let index = incidents.firstIndex(where: { $0.resolvedAt == nil && !$0.interrupted }), let snapshot else { return }
        incidents[index].action = label
        incidents[index].actionBaseline = snapshot
    }
}
