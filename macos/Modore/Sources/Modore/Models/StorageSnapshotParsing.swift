import Foundation

struct StorageSnapshotComponents {
    let mount: String
    let freeGB: Double
    let usedGB: Double
    let totalGB: Double
    let usePercent: Double
    let risk: String
    /// Whether df actually reported the volume. False when collection failed and
    /// the producer emitted a 0GB sentinel; older results without the flag are
    /// treated as measured only when a real total is present.
    let volumeMeasured: Bool
    let cleanupCandidates: [StorageItem]
    let recoveryCandidates: [StorageItem]
    let reviewCandidates: [StorageItem]
    let developerToolchains: [StorageItem]
    let applications: [StorageItem]
    let simulatorDevices: [SimulatorDevice]
    let accessIssues: [StorageAccessIssue]
    let runtimeSignals: [RuntimeSignal]
    let browserAutomation: BrowserAutomationStatus

    init?(json: [String: Any]?) {
        guard let json, let volume = json["volume"] as? [String: Any] else { return nil }
        mount = volume["mount"] as? String ?? "/"
        freeGB = StorageSnapshotParser.double(volume["freeGB"])
        usedGB = StorageSnapshotParser.double(volume["usedGB"])
        totalGB = StorageSnapshotParser.double(volume["totalGB"])
        usePercent = StorageSnapshotParser.double(volume["usePercent"])
        risk = volume["risk"] as? String ?? "unknown"
        if let measured = volume["measured"] as? Bool {
            volumeMeasured = measured
        } else {
            // Backward compatibility with results predating the flag: a real
            // mounted volume always reports a nonzero total.
            volumeMeasured = StorageSnapshotParser.double(volume["totalGB"]) > 0
        }
        cleanupCandidates = StorageSnapshotParser.items(json["cleanupCandidates"])
        if json["recoveryCandidates"] != nil {
            recoveryCandidates = StorageSnapshotParser.items(json["recoveryCandidates"])
        } else {
            recoveryCandidates = cleanupCandidates
        }
        reviewCandidates = StorageSnapshotParser.items(json["reviewCandidates"])
        developerToolchains = StorageSnapshotParser.items(json["developerToolchains"])
        applications = StorageSnapshotParser.items(json["applications"])
        simulatorDevices = StorageSnapshotParser.simulatorItems(json["simulatorDevices"])
        accessIssues = StorageSnapshotParser.accessItems(json["accessIssues"])
        runtimeSignals = StorageSnapshotParser.runtimeItems(json["runtimeSignals"])
        browserAutomation = BrowserAutomationStatus(
            json: json["browserAutomation"] as? [String: Any]
        )
    }
}

struct StorageSnapshotTotals {
    let reclaimableGB: Double
    let recoveryGB: Double
    let developerGB: Double
    let reviewGB: Double
    let applicationsGB: Double
    let simulatorGB: Double
    let simulatorFootprintGB: Double
    let simulatorBreakdown: [SimulatorFootprintBreakdown]
    let simulatorFootprintMeasurementIncomplete: Bool
    let inventoryGB: Double

    init(components: StorageSnapshotComponents) {
        reclaimableGB = StorageSnapshotParser.uniqueSize(
            components.cleanupCandidates.filter(\.canCleanup)
        )
        recoveryGB = StorageSnapshotParser.uniqueSize(
            components.recoveryCandidates.filter(\.canCleanup)
        )
        reviewGB = StorageSnapshotParser.uniqueSize(components.reviewCandidates)
        developerGB = StorageSnapshotParser.uniqueSize(
            components.developerToolchains.filter { !$0.kind.hasPrefix("simulator_") }
        )
        applicationsGB = StorageSnapshotParser.uniqueSize(components.applications)
        simulatorBreakdown = Self.simulatorBreakdown(components: components)
        simulatorFootprintGB = simulatorBreakdown.reduce(0) { $0 + $1.sizeGB }
        simulatorFootprintMeasurementIncomplete = simulatorBreakdown.contains {
            $0.measureStatus != "ok"
        }
        // `simulatorGB` remains the device-data total for compatibility. The
        // wider devices + runtimes + shared-cache number is explicitly named
        // `simulatorFootprintGB` so the two meanings cannot be confused.
        simulatorGB = simulatorBreakdown.first(where: {
            $0.kind == "simulator_devices"
        })?.sizeGB ?? 0
        inventoryGB = applicationsGB + simulatorGB
    }

    private struct SimulatorSource {
        let kind: String
        let sizeGB: Double
        let path: String
        let measureStatus: String
    }

    private static func simulatorBreakdown(
        components: StorageSnapshotComponents
    ) -> [SimulatorFootprintBreakdown] {
        let aggregateDevices = components.developerToolchains.filter {
            $0.kind == "simulator_devices"
        }
        var sources = components.developerToolchains
            .filter { $0.kind == "simulator_runtime" || $0.kind == "simulator_cache" }
            .map {
                SimulatorSource(
                    kind: $0.kind,
                    sizeGB: $0.sizeGB,
                    path: $0.path,
                    measureStatus: $0.measureStatus
                )
            }

        let usableAggregateDevices = aggregateDevices.filter {
            $0.measureStatus == "ok" || ($0.sizeGB.isFinite && $0.sizeGB > 0)
        }
        if !usableAggregateDevices.isEmpty {
            sources += usableAggregateDevices.map {
                SimulatorSource(
                    kind: $0.kind,
                    sizeGB: $0.sizeGB,
                    path: $0.path,
                    measureStatus: $0.measureStatus
                )
            }
        } else if !components.simulatorDevices.isEmpty {
            // Legacy snapshots could have a timed-out 0-byte aggregate while
            // every UUID row was measured successfully. Collapse those detail
            // rows into one compatibility aggregate instead of discarding the
            // known bytes or counting both representations.
            let measured = components.simulatorDevices.filter {
                $0.measureStatus == "ok"
            }
            let rootPath = components.simulatorDevices.lazy
                .map(\.path)
                .first(where: { !$0.isEmpty })
                .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
                ?? "/<simulator-devices>"
            sources.append(SimulatorSource(
                kind: "simulator_devices",
                sizeGB: measured
                    .filter { $0.sizeGB.isFinite && $0.sizeGB > 0 }
                    .reduce(0) { $0 + $1.sizeGB },
                path: rootPath,
                measureStatus: measured.count == components.simulatorDevices.count
                    ? "ok"
                    : "timed_out"
            ))
        } else {
            // No UUID compatibility rows exist, so retain an incomplete zero
            // aggregate as evidence that measurement was attempted and failed.
            sources += aggregateDevices.map {
                SimulatorSource(
                    kind: $0.kind,
                    sizeGB: $0.sizeGB,
                    path: $0.path,
                    measureStatus: $0.measureStatus
                )
            }
        }

        // A producer should emit disjoint roots, but model-side de-duplication
        // prevents a parent and one of its descendants from inflating the total.
        var roots: [String] = []
        let unique = sources
            .filter { !$0.path.isEmpty }
            .sorted {
                if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
                if $0.path != $1.path { return $0.path < $1.path }
                return $0.kind < $1.kind
            }
            .filter { source in
                let path = StorageHistoryEntry.normalizedPath(source.path)
                let covered = roots.contains { path == $0 || path.hasPrefix($0 + "/") }
                if !covered { roots.append(path) }
                return !covered
            }

        let labels = [
            "simulator_devices": "기기 데이터",
            "simulator_runtime": "런타임",
            "simulator_cache": "공유 캐시",
        ]
        return ["simulator_devices", "simulator_runtime", "simulator_cache"].compactMap { kind in
            let matching = unique.filter { $0.kind == kind }
            guard !matching.isEmpty else { return nil }
            let incompleteStatus = matching.first { $0.measureStatus != "ok" }?.measureStatus
            let size = matching
                .filter {
                    // Every positive non-ok value emitted by the scanner is a
                    // traversal result captured before the bounded command
                    // stopped. Keep it as a lower bound for devices, runtimes,
                    // and shared caches; the status still prevents history
                    // from treating it as an exact delta endpoint.
                    $0.sizeGB.isFinite && $0.sizeGB > 0
                }
                .reduce(0) { $0 + $1.sizeGB }
            return SimulatorFootprintBreakdown(
                id: kind,
                kind: kind,
                label: labels[kind] ?? kind,
                sizeGB: size,
                measureStatus: incompleteStatus ?? "ok"
            )
        }
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
