import Foundation
import SwiftUI

enum ScanState: Equatable {
    case idle
    case running
    case finished
    case failed

    var title: String {
        switch self {
        case .idle: return "대기 중"
        case .running: return "검사 실행 중"
        case .finished: return "검사 완료"
        case .failed: return "오류"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "circle.dotted"
        case .running: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .blue
        case .finished: return .green
        case .failed: return .red
        }
    }
}

struct ScanSummary {
    let overall: String
    let dangerCount: Int
    let warningCount: Int
    let message: String

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        overall = json["overall"] as? String ?? "unknown"
        dangerCount = json["dangerCount"] as? Int ?? 0
        warningCount = json["warningCount"] as? Int ?? 0
        message = json["message"] as? String ?? "검사 결과를 읽었습니다."
    }
}

struct MacOSSecurityStatus {
    let gatekeeper: String
    let sip: String
    let xprotectVersion: String

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        gatekeeper = JsonRead.string(json, "gatekeeper", "unknown")
        sip = JsonRead.string(json, "sip", "unknown")
        xprotectVersion = JsonRead.string(json, "xprotectVersion")
    }

    var gatekeeperEnabled: Bool {
        gatekeeper.localizedCaseInsensitiveContains("enabled")
    }

    var sipEnabled: Bool {
        sip.localizedCaseInsensitiveContains("enabled")
    }
}

enum JsonRead {
    static func string(_ json: [String: Any], _ key: String, _ fallback: String = "") -> String {
        if let value = json[key] as? String { return value }
        if let value = json[key] as? NSNumber { return value.stringValue }
        return fallback
    }

    static func int(_ json: [String: Any], _ key: String, _ fallback: Int = 0) -> Int {
        if let value = json[key] as? NSNumber { return value.intValue }
        if let value = json[key] as? String { return Int(value) ?? fallback }
        return fallback
    }

    static func double(_ json: [String: Any], _ key: String, _ fallback: Double = 0) -> Double {
        if let value = json[key] as? NSNumber { return value.doubleValue }
        if let value = json[key] as? String { return Double(value) ?? fallback }
        return fallback
    }
}

struct ScanFinding: Identifiable {
    let id = UUID()
    let level: String
    let category: String
    let title: String
    let detail: String

    init?(json: [String: Any]) {
        level = JsonRead.string(json, "level", "info")
        category = JsonRead.string(json, "category")
        title = JsonRead.string(json, "title", "확인 항목")
        detail = JsonRead.string(json, "detail")
    }
}

struct CpuRow: Identifiable {
    let id = UUID()
    let name: String
    let pid: Int
    let cpu: Double
    let memoryMB: Double
    let path: String
    let risk: String

    init?(json: [String: Any]) {
        name = JsonRead.string(json, "name", "process")
        pid = JsonRead.int(json, "pid_")
        cpu = JsonRead.double(json, "cpu")
        memoryMB = JsonRead.double(json, "memoryMB")
        path = JsonRead.string(json, "path")
        risk = JsonRead.string(json, "risk", "unknown")
    }
}

struct NetworkRow: Identifiable {
    let id = UUID()
    let process: String
    let remoteAddress: String
    let remotePort: Int
    let risk: String

    init?(json: [String: Any]) {
        process = JsonRead.string(json, "process", "process")
        remoteAddress = JsonRead.string(json, "remoteAddress")
        remotePort = JsonRead.int(json, "remotePort")
        risk = JsonRead.string(json, "risk", "unknown")
    }
}

struct AutorunRow: Identifiable {
    let id = UUID()
    let category: String
    let entry: String
    let image: String
    let risk: String

    init?(json: [String: Any]) {
        category = JsonRead.string(json, "category")
        entry = JsonRead.string(json, "entry", "자동실행 항목")
        image = JsonRead.string(json, "image")
        risk = JsonRead.string(json, "risk", "unknown")
    }
}

struct RecentInstallRow: Identifiable {
    let id = UUID()
    let installDate: String
    let name: String
    let publisher: String
    let note: String
    let risk: String

    init?(json: [String: Any]) {
        installDate = JsonRead.string(json, "installDate")
        name = JsonRead.string(json, "name", "앱")
        publisher = JsonRead.string(json, "publisher")
        note = JsonRead.string(json, "note")
        risk = JsonRead.string(json, "risk", "unknown")
    }
}

struct StorageSnapshot {
    let mount: String
    let freeGB: Double
    let usedGB: Double
    let totalGB: Double
    let usePercent: Double
    let risk: String
    let cleanupCandidates: [StorageItem]
    let reviewCandidates: [StorageItem]
    let developerToolchains: [StorageItem]
    let applications: [StorageItem]
    let simulatorDevices: [SimulatorDevice]
    let accessIssues: [StorageAccessIssue]
    let runtimeSignals: [RuntimeSignal]

    init?(json: [String: Any]?) {
        guard let json, let volume = json["volume"] as? [String: Any] else { return nil }
        mount = volume["mount"] as? String ?? "/"
        freeGB = Self.double(volume["freeGB"])
        usedGB = Self.double(volume["usedGB"])
        totalGB = Self.double(volume["totalGB"])
        usePercent = Self.double(volume["usePercent"])
        risk = volume["risk"] as? String ?? "unknown"
        cleanupCandidates = Self.items(json["cleanupCandidates"])
        reviewCandidates = Self.items(json["reviewCandidates"])
        developerToolchains = Self.items(json["developerToolchains"])
        applications = Self.items(json["applications"])
        simulatorDevices = Self.simulatorItems(json["simulatorDevices"])
        accessIssues = Self.accessItems(json["accessIssues"])
        runtimeSignals = Self.runtimeItems(json["runtimeSignals"])
    }

    var riskColor: Color {
        switch risk {
        case "danger": return .red
        case "warning": return .orange
        case "safe": return .green
        default: return .secondary
        }
    }

    var reclaimableGB: Double {
        Self.uniqueSize(cleanupCandidates)
    }

    var developerGB: Double {
        Self.uniqueSize(developerToolchains.filter { $0.kind != "simulator_devices" })
    }

    var reviewGB: Double {
        Self.uniqueSize(reviewCandidates)
    }

    var applicationsGB: Double {
        Self.uniqueSize(applications)
    }

    var simulatorGB: Double {
        let measured = simulatorDevices.filter { $0.measureStatus != "timed_out" }
        if measured.count == simulatorDevices.count, !measured.isEmpty {
            return measured.reduce(0.0) { $0 + $1.sizeGB }
        }
        return developerToolchains.first(where: { $0.kind == "simulator_devices" })?.sizeGB
            ?? measured.reduce(0.0) { $0 + $1.sizeGB }
    }

    var inventoryGB: Double {
        applicationsGB + simulatorGB
    }

    var reclaimableText: String {
        if cleanupCandidates.contains(where: { $0.measureStatus == "timed_out" }) {
            return reclaimableGB > 0 ? Self.gbText(reclaimableGB) + "+" : "측정 보류"
        }
        return Self.gbText(reclaimableGB)
    }

    var reviewText: String {
        Self.gbText(reviewGB)
    }

    var developerText: String {
        let counted = developerToolchains.filter { $0.kind != "simulator_devices" }
        if counted.contains(where: { $0.measureStatus == "timed_out" }) {
            return developerGB > 0 ? Self.gbText(developerGB) + "+" : "측정 보류"
        }
        return Self.gbText(developerGB)
    }

    var applicationsText: String {
        Self.gbText(applicationsGB)
    }

    var simulatorText: String {
        if simulatorDevices.contains(where: { $0.measureStatus == "timed_out" }) {
            return simulatorGB > 0 ? Self.gbText(simulatorGB) + "+" : "측정 보류"
        }
        return Self.gbText(simulatorGB)
    }

    var inventoryText: String {
        if simulatorDevices.contains(where: { $0.measureStatus == "timed_out" }) {
            return inventoryGB > 0 ? Self.gbText(inventoryGB) + "+" : "측정 보류"
        }
        return Self.gbText(inventoryGB)
    }

    var attentionRuntimeSignals: [RuntimeSignal] {
        let booted = runtimeSignals.filter { $0.kind == "booted_simulator" }
        let warnings = runtimeSignals.filter { $0.kind != "booted_simulator" && $0.risk == "warning" }
        if !booted.isEmpty || !warnings.isEmpty {
            return booted + warnings
        }
        return runtimeSignals.filter { $0.kind == "process_count" && $0.count > 0 && $0.risk != "safe" }
    }

    private static func items(_ value: Any?) -> [StorageItem] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap(StorageItem.init(json:))
    }

    private static func accessItems(_ value: Any?) -> [StorageAccessIssue] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap(StorageAccessIssue.init(json:))
    }

    private static func runtimeItems(_ value: Any?) -> [RuntimeSignal] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap(RuntimeSignal.init(json:))
    }

    private static func simulatorItems(_ value: Any?) -> [SimulatorDevice] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap(SimulatorDevice.init(json:))
    }

    private static func double(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    private static func gbText(_ value: Double) -> String {
        if value <= 0 {
            return "0GB"
        }
        return String(format: "%.1fGB", value)
    }

    private static func uniqueSize(_ items: [StorageItem]) -> Double {
        var roots: [String] = []
        var total = 0.0
        let measured = items
            .filter { $0.measureStatus != "timed_out" && $0.sizeGB > 0 && !$0.path.isEmpty }
            .sorted { $0.path.count < $1.path.count }
        for item in measured {
            let path = item.path.hasSuffix("/") ? String(item.path.dropLast()) : item.path
            let covered = roots.contains { path == $0 || path.hasPrefix($0 + "/") }
            if !covered {
                roots.append(path)
                total += item.sizeGB
            }
        }
        return total
    }
}

struct SimulatorDevice: Identifiable {
    let id: String
    let name: String
    let uuid: String
    let runtime: String
    let state: String
    let protectedByScan: Bool
    let protectionReason: String
    let cleanupID: String
    let sizeGB: Double
    let measureStatus: String

    init?(json: [String: Any]) {
        uuid = JsonRead.string(json, "uuid")
        guard !uuid.isEmpty else { return nil }
        id = uuid
        name = JsonRead.string(json, "name", "Simulator")
        runtime = JsonRead.string(json, "runtime")
        state = JsonRead.string(json, "state", "Shutdown")
        protectedByScan = json["protected"] as? Bool ?? false
        protectionReason = JsonRead.string(json, "protectionReason")
        cleanupID = JsonRead.string(json, "cleanupId")
        sizeGB = JsonRead.double(json, "sizeGB")
        measureStatus = JsonRead.string(json, "measureStatus", "ok")
    }

    var isBooted: Bool { state == "Booted" }

    var sizeText: String {
        if measureStatus == "timed_out" {
            return "측정 보류"
        }
        if sizeGB >= 0.1 {
            return String(format: "%.1fGB", sizeGB)
        }
        return String(format: "%.1fMB", max(sizeGB, 0) * 1024)
    }
}

struct StorageItem: Identifiable {
    let id = UUID()
    let risk: String
    let kind: String
    let label: String
    let sizeGB: Double
    let path: String
    let action: String
    let note: String
    let measureStatus: String
    let cleanupID: String

    init?(json: [String: Any]) {
        risk = json["risk"] as? String ?? "unknown"
        kind = json["kind"] as? String ?? "unknown"
        label = json["label"] as? String ?? kind
        if let number = json["sizeGB"] as? NSNumber {
            sizeGB = number.doubleValue
        } else if let string = json["sizeGB"] as? String {
            sizeGB = Double(string) ?? 0
        } else {
            sizeGB = 0
        }
        path = json["path"] as? String ?? ""
        action = json["action"] as? String ?? "확인 필요"
        note = json["note"] as? String ?? ""
        measureStatus = json["measureStatus"] as? String ?? "ok"
        cleanupID = json["cleanupId"] as? String ?? ""
    }

    var sizeText: String {
        if measureStatus == "timed_out" {
            return "측정 보류"
        }
        if sizeGB >= 0.1 {
            return String(format: "%.1fGB", sizeGB)
        }
        return String(format: "%.1fMB", max(sizeGB, 0) * 1024)
    }

    var canCleanup: Bool {
        !cleanupID.isEmpty && measureStatus != "timed_out"
    }
}

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

struct StorageAccessIssue: Identifiable {
    let id = UUID()
    let label: String
    let path: String
    let status: String
    let note: String

    init?(json: [String: Any]) {
        label = json["label"] as? String ?? "읽기 제한 영역"
        path = json["path"] as? String ?? ""
        status = json["status"] as? String ?? "blocked"
        note = json["note"] as? String ?? "읽기 권한이 부족할 수 있습니다."
    }
}

struct RuntimeSignal: Identifiable {
    let id = UUID()
    let kind: String
    let label: String
    let count: Int
    let risk: String
    let action: String
    let note: String

    init?(json: [String: Any]) {
        kind = JsonRead.string(json, "kind", "process_count")
        label = JsonRead.string(json, "label", "실행 신호")
        count = JsonRead.int(json, "count")
        risk = JsonRead.string(json, "risk", "info")
        action = JsonRead.string(json, "action", "확인 필요")
        note = JsonRead.string(json, "note")
    }

    var countText: String {
        if kind == "booted_simulator" {
            return "Booted"
        }
        return "\(count)개"
    }
}
