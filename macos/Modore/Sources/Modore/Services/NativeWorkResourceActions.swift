import Darwin
import Foundation

extension NativeWorkResources {
    func connect(_ request: [String: Any]) throws -> [String: Any] {
        let action = request["action"] as? String ?? "", (project, provider, session) = try project(request)
        return try locked { state in
            if action == "unbind" {
                state["bindings"] = (state["bindings"] as? [[String: Any]] ?? []).filter { !($0["project"] as? String == project && Self.same($0, session: session, provider: provider) && $0["resourceID"] as? String == request["id"] as? String) }
                return ["message": "프로젝트 기기 연결을 해제했습니다."]
            }
            let rows = try devices() + volumes().0
            guard Set(rows.compactMap { $0["id"] as? String }).count == rows.count else { throw NativeFileTree.fail("중복된 자원 식별자가 있어 중단했습니다.") }
            let row: [String: Any]
            if let id = request["id"] as? String, !id.isEmpty {
                guard let found = rows.first(where: { $0["id"] as? String == id }), found["available"] as? Bool == true else { throw NativeFileTree.fail("대상을 찾지 못했거나 사용할 수 없습니다.") }; row = found
            } else {
                guard let runtime = request["runtime"] as? String, !runtime.isEmpty else { throw NativeFileTree.fail("재사용할 runtime ID를 지정하세요.") }
                if let assigned = try assigned(state, request: request, rows: rows) { row = assigned }
                else {
                    let kind = request["deviceType"] as? String ?? ""
                    let candidates = rows.filter { r in r["kind"] as? String == "simulator" && r["runtime"] as? String == runtime && r["available"] as? Bool == true
                        && (kind.isEmpty || r["deviceType"] as? String == kind) && !Self.unresolved(state, id: r["id"] as? String ?? "").contains { !Self.same($0, session: session, provider: provider) } }
                    guard let selected = candidates.sorted(by: { a, b in
                        let ar = a["state"] as? String == "Booted", br = b["state"] as? String == "Booted"
                        if ar != br { return ar }; let ab = !(a["lastBooted"] as? String ?? "").isEmpty, bb = !(b["lastBooted"] as? String ?? "").isEmpty
                        return ab == bb ? (a["id"] as? String ?? "") < (b["id"] as? String ?? "") : ab
                    }).first else { throw NativeFileTree.fail("일치하는 기존 기기가 없습니다. 자동으로 새 기기를 만들지 않습니다.") }; row = selected
                }
            }
            let id = row["id"] as! String, runtime = row["runtime"] as! String, kind = row["deviceType"] as! String
            if action == "bind" {
                guard !provider.isEmpty, row["fingerprint"] as? String == request["fingerprint"] as? String else { throw NativeFileTree.fail("기기 식별 또는 세션 제공자를 확인하세요.") }
                var bindings = state["bindings"] as? [[String: Any]] ?? []
                bindings.removeAll { $0["project"] as? String == project && Self.same($0, session: session, provider: provider) && $0["runtime"] as? String == runtime && $0["deviceType"] as? String == kind }
                bindings.append(["resourceID": id, "project": project, "provider": provider, "session": session, "runtime": runtime, "deviceType": kind, "fingerprint": row["fingerprint"]!])
                state["bindings"] = bindings
                return ["message": "프로젝트 기기 설정을 저장했습니다. 사용 등록이 만료돼도 유지됩니다."]
            }
            if let expected = request["fingerprint"] as? String, !expected.isEmpty, expected != row["fingerprint"] as? String { throw NativeFileTree.fail("기기 식별이 바뀌었습니다.") }
            if row["kind"] as? String == "simulator" {
                var scoped = request; scoped["runtime"] = runtime; scoped["deviceType"] = kind
                if let assigned = try assigned(state, request: scoped, rows: rows), assigned["id"] as? String != id { throw NativeFileTree.fail("앱에 지정된 기기와 다릅니다.") }
                guard !Self.unresolved(state, id: id).contains(where: { !Self.same($0, session: session, provider: provider) }) else { throw NativeFileTree.fail("지정된 기기를 다른 세션이 사용 중입니다.") }
            }
            var leases = state["leases"] as? [[String: Any]] ?? []
            guard !leases.contains(where: { Self.same($0, session: session, provider: provider) && $0["resourceID"] as? String == id && $0["lifetime"] as? String == "turn" && $0["releasedAt"] == nil }) else { throw NativeFileTree.fail("턴 테스트로 등록된 기기입니다. begin-test로 재사용하거나 hold로 유지하세요.") }
            leases.removeAll { Self.same($0, session: session, provider: provider) && $0["resourceID"] as? String == id }
            let now = Date().timeIntervalSince1970
            leases.append(["resourceID": id, "session": session, "project": project, "provider": provider, "updatedAt": now, "expiresAt": now + 900])
            state["leases"] = leases
            return ["resource": row, "leases": leases.filter { $0["resourceID"] as? String == id && ($0["expiresAt"] as? Double ?? 0) > now && $0["releasedAt"] == nil },
                "instruction": "이 UDID를 모든 simctl/시뮬레이터 도구 호출에 명시하세요. 5분마다 heartbeat, 종료 시 release. 기기를 새로 만들지 마세요."]
        }
    }
    private func freeBytes() -> Int64? {
        var info = statfs(); guard statfs(home.path, &info) == 0 else { return nil }
        let (bytes, overflow) = Int64(info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize)); return overflow ? nil : bytes
    }
    func mutate(_ request: [String: Any]) throws -> [String: Any] {
        let action = request["action"] as? String ?? ""
        guard ["boot", "shutdown", "eject", "prefer"].contains(action) else { throw NativeFileTree.fail("지원하지 않는 동작입니다. 시뮬레이터 기기는 보존합니다.") }
        return try locked { state in
            let rows = try devices() + volumes().0
            guard let id = request["id"] as? String, let row = rows.first(where: { $0["id"] as? String == id }),
                  let fingerprint = request["fingerprint"] as? String, row["fingerprint"] as? String == fingerprint,
                  row["available"] as? Bool == true else { throw NativeFileTree.fail("대상 식별이 바뀌었습니다. 새로 확인하세요.") }
            if ["shutdown", "eject"].contains(action), !Self.unresolved(state, id: id).isEmpty, request["override"] as? Bool != true { throw NativeFileTree.fail("연결된 세션의 종료를 확인하지 못했습니다. 영향 경고를 확인하세요.") }
            let simulator = row["kind"] as? String == "simulator"
            if action == "prefer" {
                guard simulator else { throw NativeFileTree.fail("시뮬레이터만 기본 지정 가능합니다.") }
                var preferred = state["preferred"] as? [String: String] ?? [:], runtime = row["runtime"] as? String ?? ""
                preferred[runtime + "/" + (row["deviceType"] as? String ?? "")] = id; preferred[runtime + "/"] = id; state["preferred"] = preferred
                return ["message": "공용 재사용 기기로 지정했습니다."]
            }
            guard simulator ? action != "eject" : action == "eject" else { throw NativeFileTree.fail("기기 종류와 동작이 맞지 않습니다.") }
            let executable = simulator ? "/usr/bin/xcrun" : "/usr/sbin/diskutil"
            let args = simulator ? ["simctl", action, id] : ["eject", row["path"] as? String ?? ""]
            var receipt: [String: Any] = ["id": UUID().uuidString.lowercased(), "resource": row, "action": action, "startedAt": Date().timeIntervalSince1970,
                "status": "attempting", "freeBytesBefore": freeBytes() as Any? ?? NSNull()]
            let name = "receipt-" + (receipt["id"] as! String) + ".json"
            try registry.save(receipt, name: name)
            do { receipt["output"] = String(decoding: try command(executable, args, 45), as: UTF8.self); receipt["status"] = "succeeded" }
            catch { receipt["output"] = error.localizedDescription; receipt["status"] = "failed" }
            receipt["finishedAt"] = Date().timeIntervalSince1970
            do {
                let fresh: [[String: Any]]
                if simulator { fresh = try devices() }
                else { let (volumes, errors) = volumes(); guard errors.isEmpty else { throw NativeFileTree.fail("사후 볼륨 조회 불완전") }; fresh = volumes }
                let item = fresh.first { $0["id"] as? String == id }
                receipt["verified"] = simulator ? item?["state"] as? String == (action == "boot" ? "Booted" : "Shutdown") : item == nil
            } catch { receipt["verified"] = false }
            receipt["freeBytesAfter"] = freeBytes() as Any? ?? NSNull()
            try registry.save(receipt, name: name)
            return ["message": (receipt["status"] as? String ?? "") + " · 사후 확인 " + ((receipt["verified"] as? Bool == true) ? "True" : "False"),
                "receipt": registry.root.appendingPathComponent(name).path, "result": receipt]
        }
    }
    func diagnose(_ request: [String: Any]) throws -> [String: Any] {
        let cwd = try NativeFileTree.resolved(URL(fileURLWithPath: request["project"] as? String ?? home.path))
        let result = try NativeCodexRPC.request("hooks/list", params: ["cwds": [cwd.path]], directory: cwd)
        guard let entry = (result["data"] as? [[String: Any]])?.first else { throw NativeFileTree.fail("Codex 훅 진단 응답 형식이 올바르지 않습니다.") }
        let hooks = (entry["hooks"] as? [[String: Any]] ?? []).filter { hook in
            guard let words = try? NativeResourceHooks.words(hook["command"] as? String ?? ""), words.count >= 3 else { return false }
            return URL(fileURLWithPath: words[0]).lastPathComponent == "modore" && ["resources", "tools"].contains(words[1]) && ["hook", "guard"].contains(words[2])
        }
        let diagnosis: [String: Any] = ["observedAt": Date().timeIntervalSince1970, "cwd": cwd.path, "stamp": try NativeResourceHooks.stamp(home),
            "hooks": hooks.map { hook in Dictionary(uniqueKeysWithValues: ["key", "eventName", "enabled", "trustStatus", "currentHash"].map { ($0, hook[$0] ?? NSNull()) }) }, "errors": entry["errors"] ?? []]
        return try locked { state in state["codexHookDiagnosis"] = diagnosis; return ["message": "Codex 실행 설정을 확인했습니다.", "diagnosis": diagnosis] }
    }
}
