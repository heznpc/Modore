import Foundation

struct StorageSnapshotComponents {
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
        freeGB = StorageSnapshotParser.double(volume["freeGB"])
        usedGB = StorageSnapshotParser.double(volume["usedGB"])
        totalGB = StorageSnapshotParser.double(volume["totalGB"])
        usePercent = StorageSnapshotParser.double(volume["usePercent"])
        risk = volume["risk"] as? String ?? "unknown"
        cleanupCandidates = StorageSnapshotParser.items(json["cleanupCandidates"])
        reviewCandidates = StorageSnapshotParser.items(json["reviewCandidates"])
        developerToolchains = StorageSnapshotParser.items(json["developerToolchains"])
        applications = StorageSnapshotParser.items(json["applications"])
        simulatorDevices = StorageSnapshotParser.simulatorItems(json["simulatorDevices"])
        accessIssues = StorageSnapshotParser.accessItems(json["accessIssues"])
        runtimeSignals = StorageSnapshotParser.runtimeItems(json["runtimeSignals"])
    }
}

struct StorageSnapshotTotals {
    let reclaimableGB: Double
    let developerGB: Double
    let reviewGB: Double
    let applicationsGB: Double
    let simulatorGB: Double
    let inventoryGB: Double

    init(components: StorageSnapshotComponents) {
        reclaimableGB = StorageSnapshotParser.uniqueSize(
            components.cleanupCandidates.filter(\.canCleanup)
        )
        reviewGB = StorageSnapshotParser.uniqueSize(components.reviewCandidates)
        developerGB = StorageSnapshotParser.uniqueSize(
            components.developerToolchains.filter { $0.kind != "simulator_devices" }
        )
        applicationsGB = StorageSnapshotParser.uniqueSize(components.applications)
        simulatorGB = Self.simulatorSize(components: components)
        inventoryGB = applicationsGB + simulatorGB
    }

    private static func simulatorSize(components: StorageSnapshotComponents) -> Double {
        let measured = components.simulatorDevices.filter { $0.measureStatus != "timed_out" }
        if measured.count == components.simulatorDevices.count, !measured.isEmpty {
            return measured.reduce(0.0) { $0 + $1.sizeGB }
        }
        return components.developerToolchains.first(where: {
            $0.kind == "simulator_devices"
        })?.sizeGB ?? measured.reduce(0.0) { $0 + $1.sizeGB }
    }
}

private enum StorageSnapshotParser {
    static let maximumRowsPerCollection = 2_000

    static func items(_ value: Any?) -> [StorageItem] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.prefix(maximumRowsPerCollection).compactMap(StorageItem.init(json:))
    }

    static func accessItems(_ value: Any?) -> [StorageAccessIssue] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.prefix(maximumRowsPerCollection).compactMap(StorageAccessIssue.init(json:))
    }

    static func runtimeItems(_ value: Any?) -> [RuntimeSignal] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.prefix(maximumRowsPerCollection).compactMap(RuntimeSignal.init(json:))
    }

    static func simulatorItems(_ value: Any?) -> [SimulatorDevice] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.prefix(maximumRowsPerCollection).compactMap(SimulatorDevice.init(json:))
    }

    static func double(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    static func uniqueSize(_ items: [StorageItem]) -> Double {
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
