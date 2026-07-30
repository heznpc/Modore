import Foundation

enum CleanupRecipeCatalog {
    private static let fixedRecipes: Set<String> = [
        "npm_cache",
        "pnpm_store",
        "playwright_browsers",
        "gradle_cache",
        "cocoapods_cache",
        "pub_cache",
        "codex_runtime_cache",
        "codex_temp_cache",
        "claude_vm_bundles",
        "xcode_derived_data",
        "chrome_code_sign_clones",
        "innorix_ex",
    ]

    static func supportsStorageItem(recipeID: String, kind: String) -> Bool {
        if fixedRecipes.contains(recipeID) { return true }
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
    let reviewCandidates: [StorageItem]
    let developerToolchains: [StorageItem]
    let applications: [StorageItem]
    let simulatorDevices: [SimulatorDevice]
    let accessIssues: [StorageAccessIssue]
    let runtimeSignals: [RuntimeSignal]
    let browserAutomation: BrowserAutomationStatus
    let reclaimableGB: Double
    let developerGB: Double
    let reviewGB: Double
    let applicationsGB: Double
    let simulatorGB: Double
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
        reviewCandidates = components.reviewCandidates
        developerToolchains = components.developerToolchains
        applications = components.applications
        simulatorDevices = components.simulatorDevices
        accessIssues = components.accessIssues
        runtimeSignals = components.runtimeSignals
        browserAutomation = components.browserAutomation
        reclaimableGB = totals.reclaimableGB
        developerGB = totals.developerGB
        reviewGB = totals.reviewGB
        applicationsGB = totals.applicationsGB
        simulatorGB = totals.simulatorGB
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
    var hasSupportedCleanupRecipe: Bool {
        CleanupRecipeCatalog.supportsSimulator(recipeID: cleanupID, uuid: uuid)
    }

    func isProtected(by keptUUIDs: Set<String>) -> Bool {
        isBooted || keptUUIDs.contains(uuid)
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
        hasSupportedCleanupRecipe && measureStatus != "timed_out"
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
