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
        case .idle, .running, .finished: return .secondary
        case .failed: return .red
        }
    }
}

struct ScanSummary {
    let overall: String
    let dangerCount: Int
    let warningCount: Int
    let message: String

    var attentionCount: Int {
        dangerCount + warningCount
    }

    var hasDanger: Bool {
        dangerCount > 0 || overall == "danger"
    }

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
    let note: String

    init?(json: [String: Any]) {
        name = JsonRead.string(json, "name", "process")
        pid = JsonRead.int(json, "pid_")
        cpu = JsonRead.double(json, "cpu")
        memoryMB = JsonRead.double(json, "memoryMB")
        path = JsonRead.string(json, "path")
        risk = JsonRead.string(json, "risk", "unknown")
        note = JsonRead.string(json, "note")
    }

    var requiresAttention: Bool { risk == "danger" || risk == "warning" }
}

struct NetworkRow: Identifiable {
    let id = UUID()
    let process: String
    let remoteAddress: String
    let remotePort: Int
    let risk: String
    let note: String

    init?(json: [String: Any]) {
        process = JsonRead.string(json, "process", "process")
        remoteAddress = JsonRead.string(json, "remoteAddress")
        remotePort = JsonRead.int(json, "remotePort")
        risk = JsonRead.string(json, "risk", "unknown")
        note = JsonRead.string(json, "note")
    }

    var requiresAttention: Bool { risk == "danger" || risk == "warning" }
}

struct AutorunRow: Identifiable {
    let id = UUID()
    let category: String
    let entry: String
    let image: String
    let risk: String
    let note: String

    init?(json: [String: Any]) {
        category = JsonRead.string(json, "category")
        entry = JsonRead.string(json, "entry", "자동실행 항목")
        image = JsonRead.string(json, "image")
        risk = JsonRead.string(json, "risk", "unknown")
        note = JsonRead.string(json, "note")
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
