import Darwin
import Foundation

/// Read and retire only products attested by the developer packager's existing
/// receipts. Builder-only begin/track/finish commands remain source tools.
final class NativeBuildLifecycle {
    struct Artifact: Decodable {
        let id, kind, path: String
        let identity: [Int64]
        let seal: NativeArtifactEvidence.Seal?
        let removedAt: Double?
        let appHash, protection: String?
    }
    struct Link: Decodable { let path, appHash: String }
    struct Run: Decodable {
        let id, repository, output, status, processIdentity, validation: String
        let startedAt: Double
        let finishedAt: Double?
        let pid: Int32
        let artifacts: [Artifact]
        let installedLinks: [Link]
    }
    let store: NativeRegistry
    let cache: URL
    var usage: () -> [String]? = NativeArtifactEvidence.usage
    var processIdentity: (Int32) -> String? = NativeArtifactEvidence.processIdentity
    var applicationHash: (URL) -> String? = NativeArtifactEvidence.applicationHash
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        store = NativeRegistry(home.appendingPathComponent("Library/Application Support/Modore/build-artifacts"))
        cache = home.appendingPathComponent("Library/Caches/Modore/build-runtime/python")
    }
    static func contains(_ parent: String, _ path: String) -> Bool { path == parent || path.hasPrefix(parent + "/") }
    static func app(_ artifact: Artifact) -> URL {
        let path = URL(fileURLWithPath: artifact.path); return path.lastPathComponent == "Modore.app" ? path : path.appendingPathComponent("Modore.app")
    }
    private func load(_ id: String) throws -> ([String: Any], Run) {
        guard UUID(uuidString: id) != nil, let object = try store.read(id + ".json", limit: 2_000_000) else { throw NativeFileTree.fail("빌드 기록을 찾지 못했습니다.") }
        let run = try JSONDecoder().decode(Run.self, from: JSONSerialization.data(withJSONObject: object))
        guard run.id == id, ["running", "failed", "verified"].contains(run.status), run.startedAt.isFinite,
              run.repository.hasPrefix("/"), run.output.hasPrefix("/"), run.artifacts.count <= 10_000,
              Set(run.artifacts.map(\.id)).count == run.artifacts.count,
              run.artifacts.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.path.hasPrefix("/") && $0.identity.count == 2
                && ["scratch", "staging", "app", "recovery", "runtime", "evidence"].contains($0.kind) }) else { throw NativeFileTree.fail("빌드 기록의 형식·식별이 올바르지 않습니다.") }
        return (object, run)
    }
    private func allowed(_ artifact: Artifact, run: Run) -> Bool {
        let path = artifact.path
        let temporary = (try? NativeFileTree.resolved(FileManager.default.temporaryDirectory).path) ?? ""
        return [run.repository + "/build", temporary, cache.path].contains { !$0.isEmpty && path != $0 && Self.contains($0, path) }
    }
    private func sharedRuntimeMatches(_ path: URL) -> Bool {
        guard let source = try? NativeArtifactEvidence.fileHash(path),
              let shared = try? NativeArtifactEvidence.fileHash(cache.appendingPathComponent(path.lastPathComponent)) else { return false }
        return source == shared
    }
    func invoke(_ request: [String: Any]) throws -> [String: Any] {
        let arguments = request["arguments"] as? [String] ?? ["report"]
        guard let action = arguments.first, ["report", "reclaim", "link"].contains(action) else { throw NativeFileTree.fail("지원하지 않는 빌드 관리 요청입니다.") }
        var ids = Set<String>(), options: [String: String] = [:], index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--artifact-id", "--id", "--path"].contains(flag), index + 1 < arguments.count else { throw NativeFileTree.fail("빌드 관리 옵션이 올바르지 않습니다.") }
            if flag == "--artifact-id" { ids.insert(arguments[index + 1]) } else { guard options[flag] == nil else { throw NativeFileTree.fail("중복 빌드 관리 옵션") }; options[flag] = arguments[index + 1] }
            index += 2
        }
        if action == "reclaim", ids.isEmpty { throw NativeFileTree.fail("회수할 생성물을 명시적으로 선택하세요.") }
        return try store.locked {
            if action == "link" {
                guard let key = options["--id"], let path = options["--path"] else { throw NativeFileTree.fail("빌드 ID와 설치 경로가 필요합니다.") }
                let installed = try NativeArtifactEvidence.safe(URL(fileURLWithPath: path))
                var (object, run) = try load(key)
                guard let hash = applicationHash(installed), run.artifacts.contains(where: { $0.appHash == hash }) else { throw NativeFileTree.fail("설치본의 서명이 해당 빌드와 일치하지 않습니다.") }
                var links = object["installedLinks"] as? [[String: Any]] ?? []
                links.removeAll { $0["path"] as? String == installed.path }; links.append(["path": installed.path, "appHash": hash, "observedAt": Date().timeIntervalSince1970])
                object["installedLinks"] = links; try store.save(object, name: key + ".json", limit: 2_000_000); return object
            }
            return try report(reclaim: action == "reclaim", ids: ids)
        }
    }
    func report(reclaim: Bool = false, ids: Set<String> = []) throws -> [String: Any] {
        let files = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)
        guard files.count <= 10_000 else { throw NativeFileTree.fail("빌드 기록 수 제한 초과") }
        var records: [(object: [String: Any], run: Run)] = [], warnings: [String] = []
        for file in files where file.pathExtension == "json" {
            do { let value = try load(file.deletingPathExtension().lastPathComponent); records.append(value) }
            catch { warnings.append(file.lastPathComponent + ": " + error.localizedDescription) }
        }
        records.sort { $0.run.startedAt > $1.run.startedAt }
        let runs = records.map(\.run), opened = usage()
        var slots = Set<String>(), retained = Set<String>(), repositories = Set<String>(), neededCaches = Set<String>()
        for run in runs where run.status == "verified" {
            if !repositories.contains(run.repository), run.artifacts.contains(where: { $0.kind == "app" }) {
                repositories.insert(run.repository); neededCaches.formUnion(run.artifacts.filter { $0.kind == "runtime" }.map(\.path))
            }
            for artifact in run.artifacts where ["app", "recovery"].contains(artifact.kind) && FileManager.default.fileExists(atPath: artifact.path) {
                if slots.insert(run.repository + "\0" + artifact.kind).inserted { retained.insert(artifact.id) }
            }
        }
        let live = runs.filter { $0.status == "running" && processIdentity($0.pid) == $0.processIdentity }
        var links: [String: String] = [:], checked = Set<String>(), installed = Set<String>()
        for run in runs {
            for link in run.installedLinks {
                if checked.insert(link.path).inserted { links[link.path] = applicationHash(URL(fileURLWithPath: link.path)) }
                if links[link.path] == link.appHash { installed.insert(link.appHash) }
            }
        }
        var rows: [[String: Any]] = [], seen = Set<String>()
        for record in records {
            let run = record.run
            var object = record.object
            for artifact in run.artifacts where seen.insert(artifact.path).inserted {
                let path = URL(fileURLWithPath: artifact.path)
                var reason = "", eligible = false
                let isLive = live.contains { $0.id == run.id }
                let lock = URL(fileURLWithPath: run.output).appendingPathComponent(".pch-build.lock").path
                let cacheLock = cache.appendingPathComponent(".pch-runtime-cache.lock").path
                if artifact.removedAt != nil { reason = "회수 완료" }
                else if !FileManager.default.fileExists(atPath: path.path) { reason = "이미 교체되었거나 경로가 없습니다" }
                else if run.status != "verified" { reason = run.status == "running" ? (isLive ? "실행 중" : "중단됨 · 검증 미완료") : "실패한 실행 · 보존" }
                else if artifact.kind == "evidence" { reason = "사용자·검증 증거 보존" }
                else if let protection = artifact.protection, !protection.isEmpty { reason = protection }
                else if artifact.seal == nil { reason = "검증 완료 기록 없음" }
                else if artifact.seal?.evidence == true { reason = "테스트·진단 증거 포함 · 보존" }
                else if artifact.kind == "runtime", neededCaches.contains(artifact.path) { reason = "현재 빌드가 사용하는 공용 런타임 캐시" }
                else if runs.contains(where: { $0.status != "verified" && $0.artifacts.contains(where: { $0.path == artifact.path }) }) { reason = "실패·중단·진행 중 실행에서도 참조 · 보존" }
                else if retained.contains(artifact.id) { reason = "최종본 1개·복구본 1개 보관 정책" }
                else if artifact.appHash.map({ installed.contains($0) }) == true { reason = "현재 연결된 설치본의 빌드 · 보존" }
                else if live.contains(where: { Self.contains($0.output, artifact.path) || Self.contains(artifact.path, $0.output) }) { reason = "다른 빌드 실행이 사용 중" }
                else if !warnings.isEmpty { reason = "읽지 못한 빌드 기록이 있어 보존합니다" }
                else if !allowed(artifact, run: run) { reason = "관리 범위 밖의 경로 · 보존" }
                else if opened == nil { reason = "현재 사용 여부를 확인하지 못했습니다" }
                else if opened!.contains(lock) { reason = "빌드 잠금 사용 중 · 보존" }
                else if artifact.kind == "runtime", opened!.contains(cacheLock) { reason = "공용 런타임 캐시를 다른 빌드가 사용 중" }
                else if opened!.contains(where: { Self.contains(artifact.path, $0) }) { reason = "열린 파일·실행 프로세스가 사용 중" }
                else {
                    do {
                        if try NativeArtifactEvidence.identity(path) != artifact.identity || NativeArtifactEvidence.seal(path) != artifact.seal { reason = "검증 이후 내용·식별 변경 · 보존" }
                        else if ["app", "recovery"].contains(artifact.kind), applicationHash(Self.app(artifact)) == nil { reason = "앱 서명 재검증 실패" }
                        else if artifact.kind == "runtime", !Self.contains(cache.path, path.path),
                                !sharedRuntimeMatches(path) { reason = "동일한 공용 런타임을 확인하지 못했습니다" }
                        else { eligible = true; reason = "검증 완료 · 변경·현재 사용 미관측" }
                    } catch { reason = error.localizedDescription }
                }
                if eligible && reclaim && ids.contains(artifact.id), let seal = artifact.seal {
                    do {
                        guard let current = usage(), !current.contains(lock), !(artifact.kind == "runtime" && current.contains(cacheLock)),
                              !current.contains(where: { Self.contains(artifact.path, $0) }) else { throw NativeFileTree.fail("실행 직전 사용 상태 변경 · 보존") }
                        // Persist intent before removing any payload. A killed worker
                        // cannot silently make a partially removed product eligible.
                        var artifacts = object["artifacts"] as? [[String: Any]] ?? []
                        guard let index = artifacts.firstIndex(where: { $0["id"] as? String == artifact.id }) else { throw NativeFileTree.fail("회수 기록 식별 변경") }
                        artifacts[index]["protection"] = "회수 시작 기록 · 종료 여부 확인 필요"
                        object["artifacts"] = artifacts; try store.save(object, name: run.id + ".json", limit: 2_000_000)
                        try NativeArtifactEvidence.remove(path, expected: seal, identity: artifact.identity)
                        artifacts[index].removeValue(forKey: "protection"); artifacts[index]["removedAt"] = Date().timeIntervalSince1970
                        object["artifacts"] = artifacts; try store.save(object, name: run.id + ".json", limit: 2_000_000)
                        reason = "회수 완료"
                    } catch { reason = error.localizedDescription }
                    eligible = false
                }
                rows.append(["id": artifact.id, "runID": run.id, "kind": artifact.kind, "path": artifact.path,
                    "bytes": artifact.seal?.bytes as Any? ?? NSNull(), "eligible": eligible, "reason": reason,
                    "startedAt": run.startedAt, "finishedAt": run.finishedAt as Any? ?? NSNull(), "status": run.status, "validation": run.validation,
                    "installedPaths": run.installedLinks.filter { artifact.appHash == $0.appHash && links[$0.path] == $0.appHash }.map(\.path),
                    "previousInstalledPaths": run.installedLinks.filter { artifact.appHash == $0.appHash && links[$0.path] != $0.appHash }.map(\.path)])
            }
        }
        for repository in Set(runs.map(\.repository)) {
            let build = URL(fileURLWithPath: repository).appendingPathComponent("build")
            guard (try? NativeArtifactEvidence.safe(build)) != nil else { continue }
            for directory in (try? FileManager.default.contentsOfDirectory(at: build, includingPropertiesForKeys: nil)) ?? [] {
                guard (try? NativeFileTree.metadata(directory).st_mode & S_IFMT) == S_IFDIR else { continue }
                let names = ["Modore.app", ".python-runtime-cache", ".build", "swift"] + (((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".pch-app-backup.") })
                for name in names {
                    let path = directory.appendingPathComponent(name)
                    guard NativeFileTree.exists(path), seen.insert(path.path).inserted else { continue }
                    rows.append(["id": NativeFileTree.hash(path.path), "runID": "", "kind": "untracked", "path": path.path, "bytes": NSNull(), "eligible": false,
                        "reason": "생성·검증 기록 없음 · 자동 회수 제외", "startedAt": 0, "finishedAt": NSNull(), "status": "untracked", "validation": "", "installedPaths": [], "previousInstalledPaths": []])
                }
            }
        }
        return ["observedAt": Date().timeIntervalSince1970, "items": rows, "sharedCache": cache.path, "warnings": warnings,
            "policy": "저장소별 최종 앱 1개·복구본 1개. 검증이 끝난 생성물만 회수하며 실패·중단·사용 중·변경·증거는 보존합니다."]
    }
}
