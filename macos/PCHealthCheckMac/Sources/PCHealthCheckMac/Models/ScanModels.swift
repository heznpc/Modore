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
    let developerToolchains: [StorageItem]
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
        developerToolchains = Self.items(json["developerToolchains"])
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
        cleanupCandidates.reduce(0.0) { $0 + $1.sizeGB }
    }

    var developerGB: Double {
        developerToolchains.reduce(0.0) { $0 + $1.sizeGB }
    }

    var reclaimableText: String {
        Self.gbText(reclaimableGB)
    }

    var developerText: String {
        Self.gbText(developerGB)
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
    }

    var sizeText: String {
        measureStatus == "timed_out" ? "측정 보류" : String(format: "%.1fGB", sizeGB)
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
