import Foundation
import SwiftUI

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
    let reclaimableGB: Double
    let developerGB: Double
    let reviewGB: Double
    let applicationsGB: Double
    let simulatorGB: Double
    let inventoryGB: Double
    let attentionRuntimeSignals: [RuntimeSignal]

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

        let cleanupSize = Self.uniqueSize(cleanupCandidates)
        let reviewSize = Self.uniqueSize(reviewCandidates)
        let developerSize = Self.uniqueSize(
            developerToolchains.filter { $0.kind != "simulator_devices" }
        )
        let applicationSize = Self.uniqueSize(applications)
        let measuredDevices = simulatorDevices.filter { $0.measureStatus != "timed_out" }
        let deviceSize: Double
        if measuredDevices.count == simulatorDevices.count, !measuredDevices.isEmpty {
            deviceSize = measuredDevices.reduce(0.0) { $0 + $1.sizeGB }
        } else {
            deviceSize = developerToolchains.first(where: { $0.kind == "simulator_devices" })?.sizeGB
                ?? measuredDevices.reduce(0.0) { $0 + $1.sizeGB }
        }

        reclaimableGB = cleanupSize
        reviewGB = reviewSize
        developerGB = developerSize
        applicationsGB = applicationSize
        simulatorGB = deviceSize
        inventoryGB = applicationSize + deviceSize
        attentionRuntimeSignals = Self.attentionSignals(runtimeSignals)
    }

    var riskColor: Color {
        switch risk {
        case "danger": return .red
        case "warning": return .orange
        case "safe": return .green
        default: return .secondary
        }
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

    private static func attentionSignals(_ signals: [RuntimeSignal]) -> [RuntimeSignal] {
        let booted = signals.filter { $0.kind == "booted_simulator" }
        let warnings = signals.filter { $0.kind != "booted_simulator" && $0.risk == "warning" }
        if !booted.isEmpty || !warnings.isEmpty {
            return booted + warnings
        }
        return signals.filter { $0.kind == "process_count" && $0.count > 0 && $0.risk != "safe" }
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
