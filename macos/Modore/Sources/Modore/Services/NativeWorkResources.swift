import Darwin
import Foundation

/// App resource operations share leases.json with source lifecycle hooks.
/// simctl/diskutil remain explicit system tools; plist/JSON, leases and receipts
/// are handled by Swift. Inventory observations never establish session ownership.
final class NativeWorkResources {
    typealias Command = (String, [String], TimeInterval) throws -> Data
    let home: URL
    let registry: NativeRegistry
    var command: Command = { executable, arguments, timeout in
        let result = try NativeCommand.run(executable, arguments, timeout: timeout, limit: 8_000_000)
        guard result.status == 0 else { throw NativeFileTree.fail(String(result.errorText.prefix(2000))) }; return result.output
    }
    var deviceInventory: (() throws -> [[String: Any]])?
    var volumeInventory: (() -> ([[String: Any]], [String]))?
    var observation: (([[String: Any]]) -> ([String: [[String: Any]]], [String]))?
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home; registry = NativeRegistry(home.appendingPathComponent("Library/Application Support/Modore/work-resources"))
    }
    static func identity(_ session: String, provider: String = "") throws -> (String, String) {
        let parts = session.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, ["codex", "claude", "gemini", "kiro", "claude desktop"].contains(parts[0]) {
            guard provider.isEmpty || provider == parts[0] else { throw NativeFileTree.fail("세션 제공자가 일치하지 않습니다.") }; return (parts[0], parts[1])
        }
        return (provider, session)
    }
    static func same(_ row: [String: Any], session: String, provider: String) -> Bool {
        guard let a = try? identity(row["session"] as? String ?? "", provider: row["provider"] as? String ?? ""),
              let b = try? identity(session, provider: provider) else { return false }
        return a.1 == b.1 && (a.0.isEmpty || b.0.isEmpty || a.0 == b.0)
    }
    private func state() throws -> [String: Any] {
        var state = try registry.read("leases.json", limit: 8_000_000) ?? ["leases": [], "preferred": [:], "bindings": []]
        guard var leases = state["leases"] as? [[String: Any]], state["preferred"] is [String: String],
              state["bindings"] == nil || state["bindings"] is [[String: Any]] else { throw NativeFileTree.fail("자원 사용 기록 형식이 올바르지 않습니다.") }
        for index in leases.indices {
            guard let session = leases[index]["session"] as? String, leases[index]["resourceID"] is String,
                  leases[index]["project"] is String, let updated = leases[index]["updatedAt"] as? Double,
                  let expires = leases[index]["expiresAt"] as? Double, updated.isFinite, expires.isFinite else { throw NativeFileTree.fail("자원 사용 기록이 불완전합니다.") }
            let (provider, raw) = try Self.identity(session, provider: leases[index]["provider"] as? String ?? "")
            leases[index]["session"] = raw; if !provider.isEmpty { leases[index]["provider"] = provider }
            if leases[index]["releasedAt"] == nil, expires < updated { leases[index]["releasedAt"] = updated }
        }
        for binding in state["bindings"] as? [[String: Any]] ?? [] {
            guard ["provider", "session", "project", "resourceID", "runtime", "deviceType", "fingerprint"].allSatisfy({ binding[$0] is String }) else { throw NativeFileTree.fail("프로젝트 기기 연결 기록이 불완전합니다.") }
        }
        state["leases"] = leases; if state["bindings"] == nil { state["bindings"] = [[String: Any]]() }; return state
    }
    func locked<T>(_ body: (inout [String: Any]) throws -> T) throws -> T {
        try registry.locked {
            var value = try state(); let result = try body(&value)
            try registry.save(value, name: "leases.json", limit: 8_000_000); return result
        }
    }
    static func simulatorRows(_ payload: [String: Any]) throws -> [[String: Any]] {
        guard let devices = payload["devices"] as? [String: [[String: Any]]] else { throw NativeFileTree.fail("시뮬레이터 응답 형식이 올바르지 않습니다.") }
        var rows: [[String: Any]] = []
        for runtime in devices.keys.sorted() {
            for device in devices[runtime] ?? [] {
                guard let id = device["udid"] as? String, UUID(uuidString: id) != nil,
                      let name = device["name"] as? String, let state = device["state"] as? String else { throw NativeFileTree.fail("시뮬레이터 식별 응답이 불완전합니다.") }
                let kind = device["deviceTypeIdentifier"] as? String ?? "", path = device["dataPath"] as? String ?? ""
                rows.append(["id": id, "kind": "simulator", "name": name, "runtime": runtime, "deviceType": kind,
                    "state": state, "available": device["isAvailable"] as? Bool ?? false, "path": path,
                    "lastBooted": device["lastBootedAt"] as? String ?? "", "fingerprint": NativeFileTree.hash(id + runtime + kind + path)])
            }
        }
        for index in rows.indices {
            rows[index]["duplicates"] = rows.filter { ($0["id"] as? String) != (rows[index]["id"] as? String)
                && ($0["runtime"] as? String) == (rows[index]["runtime"] as? String)
                && ($0["deviceType"] as? String) == (rows[index]["deviceType"] as? String)
                && !((rows[index]["deviceType"] as? String) ?? "").isEmpty }.compactMap { $0["id"] as? String }
        }
        return rows
    }
    func devices() throws -> [[String: Any]] {
        if let deviceInventory { return try deviceInventory() }
        guard let object = try JSONSerialization.jsonObject(with: command("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], 20)) as? [String: Any] else { throw NativeFileTree.fail("시뮬레이터 응답을 해석하지 못했습니다.") }
        return try Self.simulatorRows(object)
    }
    func volumes() -> ([[String: Any]], [String]) {
        if let volumeInventory { return volumeInventory() }
        var rows: [[String: Any]] = [], errors: [String] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        do {
            let paths = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)
            guard paths.count <= 64 else { throw NativeFileTree.fail("볼륨 수 제한 초과") }
            for path in paths {
                if (try? NativeFileTree.metadata(path).st_mode & S_IFMT) == S_IFLNK { continue }
                do {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { throw NativeFileTree.fail("볼륨 조회 시간 초과") }
                    let data = try command("/usr/sbin/diskutil", ["info", "-plist", path.path], min(5, remaining))
                    guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw NativeFileTree.fail("볼륨 plist 형식 오류") }
                    guard object["Internal"] as? Bool == false, let mount = object["MountPoint"] as? String,
                          let id = object["VolumeUUID"] as? String, let device = object["DeviceIdentifier"] as? String else { continue }
                    rows.append(["id": id, "kind": "volume", "name": object["VolumeName"] as? String ?? path.lastPathComponent,
                        "runtime": "", "deviceType": "", "state": "Mounted", "available": true, "path": mount, "lastBooted": "", "duplicates": [],
                        "fingerprint": NativeFileTree.hash(id + device + mount)])
                } catch { errors.append(path.lastPathComponent + ": " + error.localizedDescription) }
            }
        } catch { errors.append(error.localizedDescription) }
        return (rows, errors)
    }
    static func processEvidence(_ data: Data, rows: [[String: Any]]) -> [String: [[String: Any]]] {
        var processes: [Int: [String: Any]] = [:], resources: [Int: Set<String>] = [:], pid: Int?, descriptor = ""
        for field in data.split(separator: 0) {
            var bytes = Array(field); while bytes.first == 10 { bytes.removeFirst() }
            guard let tag = bytes.first else { continue }; let value = String(decoding: bytes.dropFirst(), as: UTF8.self)
            if tag == 112 { pid = Int(value); descriptor = ""; if let pid { processes[pid] = ["pid": pid, "name": "", "cwd": ""] } }
            else if let pid {
                if tag == 99 { processes[pid]?["name"] = value }
                else if tag == 102 { descriptor = value }
                else if tag == 110 {
                    if descriptor == "cwd" { processes[pid]?["cwd"] = value }
                    for row in rows {
                        if let base = row["path"] as? String, !base.isEmpty, NativeBuildLifecycle.contains(base, value), let id = row["id"] as? String { resources[pid, default: []].insert(id) }
                    }
                }
            }
        }
        var result: [String: [[String: Any]]] = [:]
        for (pid, ids) in resources { for id in ids { if let process = processes[pid] { result[id, default: []].append(process) } } }
        return result
    }
    func observe(_ rows: [[String: Any]]) -> ([String: [[String: Any]]], [String]) {
        if let observation { return observation(rows) }
        do {
            let result = try NativeCommand.run("/usr/sbin/lsof", ["-nP", "-F0pcfn"], timeout: 8, limit: 8_000_000)
            let warnings = (result.status == 0 || result.status == 1) && result.error.isEmpty ? [] : ["일부 프로세스의 열린 파일을 확인하지 못했습니다. 관찰된 프로세스만 표시합니다."]
            return (Self.processEvidence(result.output, rows: rows), warnings)
        } catch { return ([:], ["프로세스 점유 측정 불완전 · 점유 없음으로 판단하지 않습니다."]) }
    }
    static func unresolved(_ state: [String: Any], id: String) -> [[String: Any]] {
        (state["leases"] as? [[String: Any]] ?? []).filter { $0["resourceID"] as? String == id && $0["releasedAt"] == nil }
    }
    func snapshot() throws -> [String: Any] {
        var rows: [[String: Any]] = [], warnings: [String] = []
        do { rows = try devices() } catch { warnings.append("시뮬레이터 조회 실패: " + error.localizedDescription) }
        let (volumes, errors) = volumes(); rows += volumes; warnings += errors
        let (evidence, observedErrors) = observe(rows); warnings += observedErrors
        return try locked { state in
            let now = Date().timeIntervalSince1970, leases = state["leases"] as? [[String: Any]] ?? [], preferred = state["preferred"] as? [String: String] ?? [:]
            let bindings = state["bindings"] as? [[String: Any]] ?? [], live = Set(rows.filter { $0["available"] as? Bool == true }.compactMap { $0["id"] as? String })
            for index in rows.indices {
                let id = rows[index]["id"] as? String ?? ""
                rows[index]["leases"] = leases.filter { $0["resourceID"] as? String == id && ($0["expiresAt"] as? Double ?? 0) > now && $0["releasedAt"] == nil }
                rows[index]["expiredLeases"] = leases.filter { $0["resourceID"] as? String == id && ($0["expiresAt"] as? Double ?? 0) <= now }
                rows[index]["processes"] = evidence[id] ?? []; rows[index]["preferred"] = preferred.values.contains(id)
                rows[index]["managedTest"] = (state["testRuns"] as? [String: Any])?[id] ?? NSNull()
                rows[index]["bindings"] = bindings.filter { $0["resourceID"] as? String == id }
            }
            for (key, id) in preferred where !live.contains(id) { warnings.append("기본 기기 확인 필요: " + key + " → " + id) }
            for binding in bindings where !live.contains(binding["resourceID"] as? String ?? "") { warnings.append("프로젝트 연결 기기 확인 필요: " + (binding["project"] as? String ?? "") + " → " + (binding["resourceID"] as? String ?? "")) }
            return ["observedAt": now, "resources": rows, "browsers": Array((state["browserRuns"] as? [String: [String: Any]] ?? [:]).values), "warnings": warnings,
                "hookStatus": NativeResourceHooks.status(state, home: home), "coverage": "프로세스 연결은 열린 파일 관찰, 세션 연결은 명시적 사용 등록입니다. 미등록 세션의 소속은 알 수 없습니다."]
        }
    }
    func project(_ request: [String: Any]) throws -> (String, String, String) {
        guard let project = request["project"] as? String, let session = request["session"] as? String,
              project.hasPrefix("/"), !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, session.count <= 256 else { throw NativeFileTree.fail("실제 프로젝트 절대 경로와 세션 ID가 필요합니다.") }
        let resolved = try NativeFileTree.resolved(URL(fileURLWithPath: project)), fd = try NativeFileTree.directory(resolved); close(fd)
        let (provider, raw) = try Self.identity(session.trimmingCharacters(in: .whitespacesAndNewlines), provider: request["provider"] as? String ?? "")
        return (resolved.path, provider, raw)
    }
    func assigned(_ state: [String: Any], request: [String: Any], rows: [[String: Any]]) throws -> [String: Any]? {
        let (project, provider, session) = try project(request), runtime = request["runtime"] as? String ?? "", kind = request["deviceType"] as? String ?? ""
        func compatible(_ row: [String: Any]) -> Bool { row["kind"] as? String == "simulator" && (runtime.isEmpty || row["runtime"] as? String == runtime) && (kind.isEmpty || row["deviceType"] as? String == kind) }
        let bindings = (state["bindings"] as? [[String: Any]] ?? []).filter { $0["project"] as? String == project && (runtime.isEmpty || $0["runtime"] as? String == runtime) && (kind.isEmpty || $0["deviceType"] as? String == kind) }
        let own = bindings.filter { Self.same($0, session: session, provider: provider) }
        let leases = (state["leases"] as? [[String: Any]] ?? []).filter { lease in Self.same(lease, session: session, provider: provider) && lease["project"] as? String == project && lease["releasedAt"] == nil && rows.contains { $0["id"] as? String == lease["resourceID"] as? String && compatible($0) } }
        let candidates = !own.isEmpty ? own : (!leases.isEmpty ? leases : bindings), ids = Set(candidates.compactMap { $0["resourceID"] as? String })
        guard ids.count <= 1 else { throw NativeFileTree.fail("연결된 기기가 여러 대입니다. OS·기종 또는 기기 ID를 명시하세요.") }
        var id = ids.first
        let preferred = state["preferred"] as? [String: String] ?? [:]
        if id == nil, !runtime.isEmpty { id = preferred[runtime + "/" + kind] ?? preferred[runtime + "/"] }
        guard let id else { return nil }
        guard let row = rows.first(where: { $0["id"] as? String == id }), row["available"] as? Bool == true, compatible(row) else { throw NativeFileTree.fail("지정된 기기가 없거나 요청과 다릅니다: " + id) }
        if let bound = candidates.first(where: { $0["resourceID"] as? String == id }), let hash = bound["fingerprint"] as? String, hash != row["fingerprint"] as? String { throw NativeFileTree.fail("연결된 기기의 식별이 바뀌었습니다.") }
        return row
    }
    func invoke(_ request: [String: Any]) throws -> [String: Any] {
        let action = request["action"] as? String ?? "status"
        if action == "status" { return try snapshot() }
        if action == "diagnose-hooks" { return try diagnose(request) }
        if ["acquire", "claim", "bind", "unbind"].contains(action) { return try connect(request) }
        return try mutate(request)
    }
}
