import Foundation

enum CleanupRecipeCatalog {
    private static let fixedRecipes: Set<String> = [
        "npm_cache",
        "pnpm_store",
        "playwright_browsers",
        "gradle_cache",
        "cocoapods_cache",
        "pub_cache",
        "uv_cache",
        "swiftpm_cache",
        "homebrew_cache",
        "pip_cache",
        "codex_runtime_cache",
        "codex_temp_cache",
        "claude_vm_bundles",
        "ollama_models",
        "xcode_derived_data",
        "chrome_code_sign_clones",
        "innorix_ex",
    ]

    static func supportsStorageItem(recipeID: String, kind: String) -> Bool {
        if fixedRecipes.contains(recipeID) { return true }
        if kind == "project_residue", recipeID == "project_residue" { return true }
        if kind == "transient_workspace", recipeID == "transient_workspace" { return true }
        guard kind == "application", recipeID.hasPrefix("app_uninstall:") else { return false }
        let bundleID = String(recipeID.dropFirst("app_uninstall:".count))
        return bundleID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9.-]{1,199}$"#,
            options: .regularExpression
        ) != nil
    }

    static func supportsSimulator(recipeID: String, uuid: String) -> Bool {
        guard recipeID.hasPrefix("simulator_delete:") else { return false }
        let requested = String(recipeID.dropFirst("simulator_delete:".count))
        return UUID(uuidString: requested) != nil
            && requested.caseInsensitiveCompare(uuid) == .orderedSame
    }

    /// Recovery plans may combine only recipes whose effect is a disposable
    /// cache or a reproducible local build asset. Models, app uninstalls,
    /// simulators and service removals remain individual decisions.
    static func batchTier(recipeID: String) -> CleanupTier? {
        switch recipeID {
        case "npm_cache", "pnpm_store", "gradle_cache", "cocoapods_cache",
             "pub_cache", "uv_cache", "homebrew_cache", "pip_cache",
             "codex_temp_cache", "chrome_code_sign_clones":
            return .safe
        case "playwright_browsers", "swiftpm_cache", "codex_runtime_cache",
             "claude_vm_bundles", "xcode_derived_data", "project_residue",
             "transient_workspace":
            return .rebuild
        default:
            return nil
        }
    }
}

struct StorageSnapshot {
    let mount: String
    let freeGB: Double
    let usedGB: Double
    let totalGB: Double
    let usePercent: Double
    let risk: String
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
    let reclaimableGB: Double
    let recoveryGB: Double
    let developerGB: Double
    let reviewGB: Double
    let applicationsGB: Double
    let simulatorGB: Double
    let simulatorFootprintGB: Double
    let simulatorBreakdown: [SimulatorFootprintBreakdown]
    let simulatorFootprintMeasurementIncomplete: Bool
    let simulatorCreationBursts: [SimulatorCreationBurst]
    let inventoryGB: Double
    let attentionRuntimeSignals: [RuntimeSignal]

    init?(json: [String: Any]?) {
        guard let components = StorageSnapshotComponents(json: json) else { return nil }
        let totals = StorageSnapshotTotals(components: components)
        mount = components.mount
        freeGB = components.freeGB
        usedGB = components.usedGB
        totalGB = components.totalGB
        usePercent = components.usePercent
        risk = components.risk
        volumeMeasured = components.volumeMeasured
        cleanupCandidates = components.cleanupCandidates
        recoveryCandidates = components.recoveryCandidates
        reviewCandidates = components.reviewCandidates
        developerToolchains = components.developerToolchains
        applications = components.applications
        simulatorDevices = components.simulatorDevices
        accessIssues = components.accessIssues
        runtimeSignals = components.runtimeSignals
        browserAutomation = components.browserAutomation
        reclaimableGB = totals.reclaimableGB
        recoveryGB = totals.recoveryGB
        developerGB = totals.developerGB
        reviewGB = totals.reviewGB
        applicationsGB = totals.applicationsGB
        simulatorGB = totals.simulatorGB
        simulatorFootprintGB = totals.simulatorFootprintGB
        simulatorBreakdown = totals.simulatorBreakdown
        simulatorFootprintMeasurementIncomplete = totals.simulatorFootprintMeasurementIncomplete
        simulatorCreationBursts = SimulatorCreationBurst.detect(in: components.simulatorDevices)
        inventoryGB = totals.inventoryGB
        attentionRuntimeSignals = Self.attentionSignals(components.runtimeSignals)
    }

    var reclaimableText: String {
        if cleanupCandidates.contains(where: {
            $0.hasSupportedCleanupRecipe && $0.measureStatus == "timed_out"
        }) {
            return reclaimableGB > 0 ? Self.gbText(reclaimableGB) + "+" : "측정 보류"
        }
        return Self.gbText(reclaimableGB)
    }

    var recoveryText: String {
        if recoveryCandidates.contains(where: {
            $0.hasSupportedCleanupRecipe && $0.measureStatus == "timed_out"
        }) {
            return recoveryGB > 0 ? Self.gbText(recoveryGB) + "+" : "측정 보류"
        }
        return Self.gbText(recoveryGB)
    }

    var reviewText: String {
        Self.gbText(reviewGB)
    }

    var developerText: String {
        let counted = developerToolchains.filter { !$0.kind.hasPrefix("simulator_") }
        if counted.contains(where: { $0.measureStatus == "timed_out" }) {
            return developerGB > 0 ? Self.gbText(developerGB) + "+" : "측정 보류"
        }
        return Self.gbText(developerGB)
    }

    var applicationsText: String {
        Self.gbText(applicationsGB)
    }

    var simulatorText: String {
        guard let devices = simulatorBreakdown.first(where: {
            $0.kind == "simulator_devices"
        }) else {
            return "0GB"
        }
        return devices.sizeText
    }

    var simulatorFootprintText: String {
        if simulatorFootprintMeasurementIncomplete {
            return simulatorFootprintGB > 0
                ? Self.gbText(simulatorFootprintGB) + "+"
                : "측정 보류"
        }
        return Self.gbText(simulatorFootprintGB)
    }

    var inventoryText: String {
        if let deviceStatus = simulatorBreakdown.first(where: {
            $0.kind == "simulator_devices"
        })?.measureStatus, deviceStatus != "ok" {
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

    private static func gbText(_ value: Double) -> String {
        if value <= 0 {
            return "0GB"
        }
        return String(format: "%.1fGB", value)
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
    let createdAt: Date?
    let path: String

    init?(json: [String: Any]) {
        uuid = JsonRead.string(json, "uuid")
        guard !uuid.isEmpty else { return nil }
        id = uuid
        name = JsonRead.string(json, "name", "Simulator")
        runtime = JsonRead.string(json, "runtime")
        // Missing or malformed state must never unlock a destructive action.
        // Only an explicit CoreSimulator `Shutdown` value is actionable.
        state = JsonRead.string(json, "state", "Unknown")
        protectedByScan = json["protected"] as? Bool ?? false
        protectionReason = JsonRead.string(json, "protectionReason")
        cleanupID = JsonRead.string(json, "cleanupId")
        let rawSizeGB = JsonRead.double(json, "sizeGB")
        sizeGB = rawSizeGB.isFinite ? max(0, rawSizeGB) : 0
        measureStatus = JsonRead.string(json, "measureStatus", "ok")
        let createdAtEpoch = JsonRead.double(json, "createdAtEpoch")
        createdAt = createdAtEpoch.isFinite && createdAtEpoch > 0
            ? Date(timeIntervalSince1970: createdAtEpoch)
            : nil
        path = JsonRead.string(json, "path")
    }

    var isBooted: Bool { state == "Booted" }
    var isShutdown: Bool { state == "Shutdown" }
    var hasSupportedCleanupRecipe: Bool {
        CleanupRecipeCatalog.supportsSimulator(recipeID: cleanupID, uuid: uuid)
    }

    func isProtected(by keptUUIDs: Set<String>) -> Bool {
        !isShutdown || keptUUIDs.contains(uuid)
    }

    var sizeText: String {
        if measureStatus == "timed_out" {
            guard sizeGB > 0 else { return "측정 보류" }
            if sizeGB >= 0.1 {
                return String(format: "최소 %.1fGB", sizeGB)
            }
            return String(format: "최소 %.1fMB", sizeGB * 1024)
        }
        if sizeGB >= 0.1 {
            return String(format: "%.1fGB", sizeGB)
        }
        return String(format: "%.1fMB", max(sizeGB, 0) * 1024)
    }
}

struct SimulatorFootprintBreakdown: Identifiable, Equatable {
    let id: String
    let kind: String
    let label: String
    let sizeGB: Double
    let measureStatus: String

    var sizeText: String {
        let measured = sizeGB <= 0 ? "0GB" : String(format: "%.1fGB", sizeGB)
        guard measureStatus != "ok" else { return measured }
        return sizeGB > 0 ? measured + "+" : "측정 보류"
    }
}

/// A timestamp-only signal that several devices for one runtime were created
/// together. It deliberately leaves `creator` unset: a creation timestamp is
/// evidence of a burst, not evidence that Claude, Codex, Xcode or another tool
/// created it.
struct SimulatorCreationBurst: Identifiable, Equatable {
    static let defaultWindowSeconds: TimeInterval = 5
    static let defaultMinimumCount = 3

    let id: String
    let runtime: String
    let deviceUUIDs: [String]
    let createdAt: Date
    let endedAt: Date
    let creator: String?
    let measureStatus: String

    var count: Int { deviceUUIDs.count }
    var creatorText: String { creator ?? "생성 주체 미확정" }

    /// Groups devices only when all timestamps fit in one bounded window.
    /// Unknown/zero timestamps and runtimes are excluded instead of being
    /// treated as 1970-era evidence.
    static func detect(
        in devices: [SimulatorDevice],
        windowSeconds: TimeInterval = defaultWindowSeconds,
        minimumCount: Int = defaultMinimumCount
    ) -> [SimulatorCreationBurst] {
        guard windowSeconds >= 0, minimumCount > 1 else { return [] }
        let timestamped = devices.compactMap { device -> (SimulatorDevice, Date)? in
            guard !device.runtime.isEmpty, let createdAt = device.createdAt else { return nil }
            return (device, createdAt)
        }
        let grouped = Dictionary(grouping: timestamped, by: { $0.0.runtime })
        var bursts: [SimulatorCreationBurst] = []

        for runtime in grouped.keys.sorted() {
            guard let values = grouped[runtime] else { continue }
            let sorted = values.sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0.uuid < $1.0.uuid
            }
            var remaining = sorted
            while remaining.count >= minimumCount {
                var left = 0
                var bestRange: ClosedRange<Int>?
                for right in remaining.indices {
                    while remaining[right].1.timeIntervalSince(remaining[left].1) > windowSeconds {
                        left += 1
                    }
                    let candidate = left...right
                    if candidate.count > (bestRange?.count ?? 0) {
                        bestRange = candidate
                    }
                }
                guard let bestRange, bestRange.count >= minimumCount else { break }

                let members = Array(remaining[bestRange])
                let uuids = members.map { $0.0.uuid }
                let first = members[0].1
                let last = members[members.count - 1].1
                bursts.append(SimulatorCreationBurst(
                    id: runtime + "|" + uuids.joined(separator: ","),
                    runtime: runtime,
                    deviceUUIDs: uuids,
                    createdAt: first,
                    endedAt: last,
                    creator: nil,
                    measureStatus: "ok"
                ))
                remaining.removeSubrange(bestRange)
            }
        }
        return bursts.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.runtime < $1.runtime
        }
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
        // A non-finite size propagates: it poisons every sum it enters, makes
        // the goal slider's range comparison false (`1 <= NaN`), and trips
        // ClosedRange's precondition -- a full-screen crash traceable to one
        // field. `Double("1e999")` and a bare 1e999 in JSON both produce one,
        // so treat it as unmeasured rather than trusting the producer.
        let rawSize: Double
        if let number = json["sizeGB"] as? NSNumber {
            rawSize = number.doubleValue
        } else if let string = json["sizeGB"] as? String {
            rawSize = Double(string) ?? 0
        } else {
            rawSize = 0
        }
        sizeGB = rawSize.isFinite ? rawSize : 0
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
        hasSupportedCleanupRecipe && measureStatus != "timed_out"
    }

    var cleanupTier: CleanupTier? {
        // A deep scan can time out while sizing the very large project tree
        // that matters most under pressure. Keep supported batch recipes in
        // the plan so their bounded approval preview gets one fresh chance to
        // measure them; execution still requires that preview to return ready.
        guard hasSupportedCleanupRecipe else { return nil }
        return CleanupRecipeCatalog.batchTier(recipeID: cleanupID)
    }

    var hasSupportedCleanupRecipe: Bool {
        CleanupRecipeCatalog.supportsStorageItem(recipeID: cleanupID, kind: kind)
            && !isProtectedDeveloperApplication
    }

    var isProtectedDeveloperApplication: Bool {
        guard kind == "application" else { return false }
        let bundleID = cleanupID.replacingOccurrences(of: "app_uninstall:", with: "")
        return bundleID == "com.apple.dt.Xcode"
            || bundleID.hasPrefix("com.apple.dt.Xcode.")
            || label.localizedCaseInsensitiveContains("Xcode")
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
    let pid: Int
    let parentPid: Int
    let elapsed: String
    let channel: String
    let state: String
    let profile: String
    let controller: String
    let memoryKB: Int
    let treeMemoryKB: Int
    let treeProcessCount: Int

    init?(json: [String: Any]) {
        kind = JsonRead.string(json, "kind", "process_count")
        label = JsonRead.string(json, "label", "실행 신호")
        count = JsonRead.int(json, "count")
        risk = JsonRead.string(json, "risk", "info")
        action = JsonRead.string(json, "action", "확인 필요")
        note = JsonRead.string(json, "note")
        pid = JsonRead.int(json, "pid")
        parentPid = JsonRead.int(json, "parentPid")
        elapsed = JsonRead.string(json, "elapsed")
        channel = JsonRead.string(json, "channel")
        state = JsonRead.string(json, "state")
        profile = JsonRead.string(json, "profile")
        controller = JsonRead.string(json, "controller")
        memoryKB = max(0, JsonRead.int(json, "memoryKB"))
        treeMemoryKB = max(memoryKB, JsonRead.int(json, "treeMemoryKB"))
        treeProcessCount = max(0, JsonRead.int(json, "treeProcessCount"))
    }

    var countText: String {
        if kind == "booted_simulator" {
            return "Booted"
        }
        return "\(count)개"
    }

    var memoryText: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(memoryKB) * 1024,
            countStyle: .memory
        )
    }

    var treeMemoryText: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(treeMemoryKB) * 1024,
            countStyle: .memory
        )
    }
}

struct BrowserAutomationStatus {
    let verdict: String
    let rootCount: Int
    let systemRootCount: Int
    let isolatedRootCount: Int
    let orphanedRootCount: Int
    let rootMemoryKB: Int
    let treeMemoryKB: Int
    let globalConfigPresent: Bool
    let globalIsolationConfigured: Bool
    let isolatedBrowserInstalled: Bool
    let configLocation: String
    let note: String

    init(json: [String: Any]?) {
        let json = json ?? [:]
        verdict = JsonRead.string(json, "verdict", "unknown")
        rootCount = JsonRead.int(json, "rootCount")
        systemRootCount = JsonRead.int(json, "systemRootCount")
        isolatedRootCount = JsonRead.int(json, "isolatedRootCount")
        orphanedRootCount = JsonRead.int(json, "orphanedRootCount")
        rootMemoryKB = max(0, JsonRead.int(json, "rootMemoryKB"))
        treeMemoryKB = max(rootMemoryKB, JsonRead.int(json, "treeMemoryKB"))
        globalConfigPresent = JsonRead.bool(json, "globalConfigPresent") ?? false
        globalIsolationConfigured = JsonRead.bool(json, "globalIsolationConfigured") ?? false
        isolatedBrowserInstalled = JsonRead.bool(json, "isolatedBrowserInstalled") ?? false
        configLocation = JsonRead.string(
            json,
            "configLocation",
            "~/.playwright/cli.config.json"
        )
        note = JsonRead.string(json, "note", "브라우저 자동화 상태를 확인하지 못했습니다.")
    }

    var needsAttention: Bool {
        verdict == "conflict_possible" || verdict == "orphaned"
    }

    var rootMemoryText: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(rootMemoryKB) * 1024,
            countStyle: .memory
        )
    }

    var treeMemoryText: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(treeMemoryKB) * 1024,
            countStyle: .memory
        )
    }
}
