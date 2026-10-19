import Darwin
import Foundation

/// Inventory, comparison and reversible per-installation quarantine. Never executes skill content.
final class NativeSkillInventory {
    static let scope = "이 설치 경로만 제외합니다. 같은 스킬의 다른 복사본과 이미 열린 세션에는 남을 수 있습니다. 새 세션에서 다시 확인하세요. 호스트·플러그인 업데이트나 재설치로 파일이 다시 생길 수 있습니다. 설정·규칙·훅은 변경하지 않습니다."
    static let configs = [".codex/config.toml", ".claude/settings.json", ".claude/plugins/installed_plugins.json"]
    let home: URL
    var bank: URL { home.appendingPathComponent("Library/Application Support/Modore/skill-backups") }
    var rename: (URL, URL) throws -> Void = NativeFileTree.renameExclusive
    var beforeSave: (([String: Any]) throws -> Void)?
    var warnings: [String] = []
    var invalidConfigs = Set<String>()
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func children(_ path: URL) -> [URL] {
        do { return try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                .map { path.appendingPathComponent($0.lastPathComponent) }.sorted { $0.path < $1.path } }
        catch {
            if NativeFileTree.exists(path) { warnings.append(path.path + "\n" + error.localizedDescription) }
            return []
        }
    }
    func isDirectory(_ path: URL) -> Bool {
        var info = stat(); return fstatat(AT_FDCWD, path.path, &info, 0) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
    func json(_ path: URL, nofollow: Bool = false) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: NativeFileTree.read(path, limit: 8 * 1024 * 1024, nofollow: nofollow)) as? [String: Any] else {
            throw NativeFileTree.fail("설정의 최상위 값이 객체가 아닙니다.")
        }
        return value
    }
    func config(_ path: String) -> [String: Any] {
        do {
            let data = try NativeFileTree.read(home.appendingPathComponent(path))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeFileTree.fail("설정의 최상위 값이 객체가 아닙니다.") }
            return object
        } catch {
            if NativeFileTree.exists(home.appendingPathComponent(path)) {
                invalidConfigs.insert(path); warnings.append(path + "\n" + error.localizedDescription)
            }
            return [:]
        }
    }
    func mapping(_ value: Any?, _ label: String) -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        warnings.append(label + ": 객체 형식이 아니므로 상태를 확인하지 못했습니다."); return [:]
    }
    func metadata(_ text: String, _ key: String, fallback: String = "") -> String {
        let front = text.components(separatedBy: "---")
        guard front.count >= 3, front[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: key) + ":\\s*[\"']?([^\\n]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: front[1], range: NSRange(front[1].startIndex..., in: front[1])),
              let range = Range(match.range(at: 1), in: front[1]) else { return fallback }
        return String(front[1][range]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    func inventory() -> [[String: Any]] {
        warnings = []; invalidConfigs = []
        var rows: [[String: Any]] = []
        func add(_ folder: URL, _ host: String, _ source: String, _ origin: String,
                 version: String = "", discovery: String = "탐색 경로에 존재 · 발견/활성 미확인") {
            let md = folder.appendingPathComponent("SKILL.md")
            var text = "", errorText = "", fingerprint = "", link = "", realPath = md.path, exists = false
            do {
                guard let kind = try? NativeFileTree.metadata(folder).st_mode,
                      kind & S_IFMT == S_IFDIR || kind & S_IFMT == S_IFLNK else { return }
                if kind & S_IFMT == S_IFLNK { link = try NativeFileTree.link(folder) }
                if !NativeFileTree.exists(md), link.isEmpty { return }
                realPath = try NativeFileTree.resolved(md).path
                var info = stat(); exists = fstatat(AT_FDCWD, md.path, &info, 0) == 0 && info.st_mode & S_IFMT == S_IFREG
                let data = try NativeFileTree.read(md)
                guard let content = String(data: data, encoding: .utf8) else { throw NativeFileTree.fail("UTF-8 문서가 아닙니다.") }
                text = content
                fingerprint = try NativeFileTree.fingerprint(folder)
            } catch { errorText = error.localizedDescription }
            rows.append(["id": NativeFileTree.hash(folder.path), "name": metadata(text, "name", fallback: folder.lastPathComponent),
                "description": metadata(text, "description"), "host": host, "source": source, "origin": origin,
                "path": folder.path, "filePath": md.path, "realPath": realPath, "link": link,
                "version": metadata(text, "version", fallback: version.isEmpty ? "명시 없음" : version),
                "hash": text.isEmpty ? "" : NativeFileTree.hash(text), "fingerprint": fingerprint,
                "manageable": host != "참고", "discovery": discovery,
                "session": "미확인 · 현재 대화 로드 상태는 조회하지 않음", "exists": exists, "error": errorText,
                "duplicates": 0, "variants": 0])
        }
        for (relative, host, source) in [(".codex/skills", "Codex", "개인 설치"), (".agents/skills", "Codex", "공유 개인 설치"),
            (".claude/skills", "Claude", "개인 설치"), (".codex/skills/.system", "Codex", "시스템 기본")] {
            for folder in children(home.appendingPathComponent(relative)) where !folder.lastPathComponent.hasPrefix(".") {
                add(folder, host, source, relative)
            }
        }
        let registry = ".claude/plugins/installed_plugins.json"
        let registryConfig = config(registry), settingsConfig = config(".claude/settings.json")
        let claudeValue = registryConfig["plugins"] ?? [:]
        let claudeValid = !invalidConfigs.contains(registry) && claudeValue is [String: Any]
        let claude = mapping(claudeValue, "Claude 설치 목록"), enabled = mapping(settingsConfig["enabledPlugins"] ?? [:], "Claude 활성 설정")
        let flags = codexPluginFlags()
        for (host, relative) in [("Codex", ".codex/plugins/cache"), ("Claude", ".claude/plugins/cache")] {
            for market in children(home.appendingPathComponent(relative)) {
                for plugin in children(market) where isDirectory(plugin) {
                    let key = plugin.lastPathComponent + "@" + market.lastPathComponent
                    for version in children(plugin) where isDirectory(version) && !version.lastPathComponent.hasPrefix(".") {
                        var discovery = "캐시 파일 · 선택 버전/활성 미확인"
                        if host == "Codex" {
                            if let flag = flags[key] { discovery = flag ? "플러그인 활성 설정 · 이 버전의 선택 여부 미확인" : "설정에서 플러그인 비활성 · 캐시 보존" }
                            else if NativeFileTree.exists(plugin.appendingPathComponent(".codex-remote-plugin-install.json")) { discovery = "원격 설치 표식 · 이 버전의 선택/활성 미확인" }
                        } else {
                            let records = claude[key] ?? []
                            let installed = records as? [[String: Any]]
                            if !claudeValid || installed == nil {
                                warnings.append("Claude 플러그인 " + key + ": 설치 기록 형식이 올바르지 않습니다.")
                                discovery = "설치 기록 오류 · 선택 버전/활성 미확인"
                            }
                            if installed?.contains(where: { $0["installPath"] as? String == version.path }) == true {
                                if let flag = Self.boolean(enabled[key]) {
                                    discovery = flag ? "등록된 버전 · 활성 설정 (실제 발견 미확인)" : "등록된 버전 · 비활성 설정"
                                } else { discovery = "등록된 버전 · 활성 설정 미확인" }
                            } else if !discovery.hasPrefix("설치 기록 오류") { discovery = "미선택 캐시 버전 · 설치 레지스트리에 없음" }
                        }
                        for folder in children(version.appendingPathComponent("skills")) {
                            add(folder, host, "플러그인 제공", key, version: version.lastPathComponent, discovery: discovery)
                        }
                    }
                }
            }
        }
        let cli = home.appendingPathComponent(".local/bin/modore")
        if (try? NativeFileTree.metadata(cli).st_mode & S_IFMT) == S_IFLNK {
            do {
                let resolved = try NativeFileTree.resolved(cli)
                add(resolved.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("skills/modore-ops"),
                    "참고", "CLI 작업본", cli.path + " → " + resolved.path, discovery: "CLI 연결 작업본의 참고 파일 · 호스트 설치 아님")
            } catch { warnings.append(cli.path + "\n" + error.localizedDescription) }
        }
        let groups = Dictionary(grouping: rows.indices, by: { rows[$0]["name"] as? String ?? "" })
        for indices in groups.values {
            let variants = Set(indices.compactMap { rows[$0]["hash"] as? String }.filter { !$0.isEmpty }).count
            for index in indices { rows[index]["duplicates"] = indices.count; rows[index]["variants"] = variants }
        }
        return rows.sorted {
            let a = ($0["name"] as? String ?? "").lowercased(), b = ($1["name"] as? String ?? "").lowercased()
            return a == b ? ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") : a < b
        }
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    func codexPluginFlags() -> [String: Bool] {
        let path = home.appendingPathComponent(".codex/config.toml")
        guard NativeFileTree.exists(path) else { return [:] }
        do {
            let data = try NativeFileTree.read(path)
            guard let text = String(data: data, encoding: .utf8) else { throw NativeFileTree.fail("UTF-8 설정이 아닙니다.") }
            return try NativeTOML.pluginFlags(text)
        } catch { warnings.append(".codex/config.toml\n" + error.localizedDescription); return [:] }
    }
    func validateOriginal(_ path: URL) throws {
        let raw = path.path
        guard raw.hasPrefix("/"), !path.pathComponents.contains("..") else { throw NativeFileTree.fail("복구 경로가 올바르지 않습니다.") }
        for root in [".codex/skills", ".codex/skills/.system", ".agents/skills", ".claude/skills"] {
            if path.deletingLastPathComponent().path == home.appendingPathComponent(root).path && !path.lastPathComponent.hasPrefix(".") { return }
        }
        for root in [".codex/plugins/cache", ".claude/plugins/cache"] {
            let prefix = home.appendingPathComponent(root).path + "/"
            if raw.hasPrefix(prefix) {
                let parts = raw.dropFirst(prefix.count).split(separator: "/")
                if parts.count == 5 && parts[3] == "skills" && parts.allSatisfy({ !$0.hasPrefix(".") }) { return }
            }
        }
        throw NativeFileTree.fail("복구 경로가 지원하는 스킬 탐색 경로 밖입니다.")
    }
    func backupRecord(_ directory: URL) throws -> [String: Any] {
        guard try NativeFileTree.metadata(directory).st_mode & S_IFMT == S_IFDIR else { throw NativeFileTree.fail("백업 경로가 링크입니다.") }
        let record = try json(directory.appendingPathComponent("manifest.json"), nofollow: true)
        for key in ["id", "name", "original", "realPath", "link", "host", "origin", "state", "error", "parentReal", "fingerprint"] {
            guard record[key] is String else { throw NativeFileTree.fail("백업 메타데이터가 불완전하거나 필드 형식이 잘못되었습니다.") }
        }
        let id = record["id"] as! String
        guard UUID(uuidString: id)?.uuidString.lowercased() == id, id == directory.lastPathComponent else { throw NativeFileTree.fail("백업 식별자가 폴더와 다릅니다.") }
        guard ["preparing", "backedUp", "disabled", "needsAttention", "failed", "restored"].contains(record["state"] as! String) else { throw NativeFileTree.fail("지원하지 않는 백업 상태입니다.") }
        for key in ["created", "restored", "restoreStarted"] where key == "created" || record[key] != nil {
            guard let value = record[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { throw NativeFileTree.fail("백업 시각 형식이 잘못되었습니다.") }
        }
        for key in ["fingerprint", "contentHash", "originalHash"] where record[key] != nil {
            guard let value = record[key] as? String, value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw NativeFileTree.fail("백업 무결성 정보가 잘못되었습니다.") }
        }
        try validateOriginal(URL(fileURLWithPath: record["original"] as! String))
        return record
    }
    func restoreFinished(_ record: [String: Any], _ directory: URL) throws -> Bool {
        guard let started = record["restoreStarted"] as? Double, started != 0,
              !NativeFileTree.exists(directory.appendingPathComponent("original")), let original = record["original"] as? String else { return false }
        let path = URL(fileURLWithPath: original), parent = path.deletingLastPathComponent()
        guard NativeFileTree.exists(path), try NativeFileTree.resolved(parent).path == parent.path, parent.path == record["parentReal"] as? String else { return false }
        return try NativeFileTree.fingerprint(path, follow: false) == record["originalHash"] as? String
    }
    func status() -> [String: Any] {
        let rows = inventory()
        var backups: [[String: Any]] = []
        for directory in children(bank) {
            guard (try? NativeFileTree.metadata(directory).st_mode & S_IFMT) == S_IFDIR else { continue }
            do {
                var record = try backupRecord(directory)
                record["backupPath"] = directory.path
                if record["state"] as? String != "restored", try restoreFinished(record, directory) {
                    record["state"] = "restored"; record["error"] = "원래 경로에 복구된 파일을 확인했습니다. 마지막 기록 저장은 중단되었습니다."
                } else if ["disabled", "backedUp", "needsAttention"].contains(record["state"] as? String ?? ""),
                          NativeFileTree.exists(URL(fileURLWithPath: record["original"] as! String)) {
                    let old = record["error"] as? String ?? ""
                    record["error"] = old + (old.isEmpty ? "" : "\n") + "현재 원래 경로에 파일이 있습니다. 재설치·재생성 여부를 확인하세요. 복구는 덮어쓰지 않습니다."
                }
                backups.append(record)
            } catch { warnings.append(directory.path + "\n백업 기록 읽기 실패\n" + error.localizedDescription) }
        }
        var seen = Set<String>()
        return ["items": rows, "backups": backups.sorted { ($0["created"] as? Double ?? 0) > ($1["created"] as? Double ?? 0) },
            "warnings": warnings.filter { seen.insert($0).inserted }, "scope": Self.scope, "observed": Date().timeIntervalSince1970]
    }
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try SecureLocalFileIO.ensurePrivateDirectory(bank)
        let fd = open(bank.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeFileTree.fail("백업 잠금을 열지 못했습니다.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              flock(fd, LOCK_EX) == 0 else { throw NativeFileTree.fail("백업 잠금을 확인하지 못했습니다.") }
        return try body()
    }
    func save(_ record: [String: Any], _ directory: URL) throws {
        try beforeSave?(record)
        let data = try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes, .sortedKeys])
        guard data.count <= 8 * 1024 * 1024 else { throw NativeFileTree.fail("백업 기록 크기 제한을 초과했습니다.") }
        try SecureLocalFileIO.atomicWrite(data, to: directory.appendingPathComponent("manifest.json"))
    }
    func selected(_ request: [String: Any]) throws -> [String: Any] {
        guard let row = inventory().first(where: { $0["id"] as? String == request["id"] as? String }) else { throw NativeFileTree.fail("설치 항목이 사라졌습니다. 새로고침하세요.") }
        guard row["manageable"] as? Bool == true else { throw NativeFileTree.fail("참고 작업본은 비활성화 대상이 아닙니다.") }
        guard (row["error"] as? String ?? "").isEmpty, let fingerprint = row["fingerprint"] as? String, !fingerprint.isEmpty else { throw NativeFileTree.fail(row["error"] as? String ?? "백업할 수 없는 항목") }
        guard request["fingerprint"] as? String == fingerprint else { throw NativeFileTree.fail("선택 후 파일이 바뀌었습니다. 새로고침하고 다시 선택하세요.") }
        return row
    }
    func disable(_ request: [String: Any]) throws -> [String: Any] {
        try withLock {
            let row = try selected(request), path = URL(fileURLWithPath: row["path"] as! String)
            try validateOriginal(path)
            let parent = path.deletingLastPathComponent(), resolved = try NativeFileTree.resolved(path)
            guard try NativeFileTree.resolved(parent).path == parent.path else { throw NativeFileTree.fail("상위 탐색 폴더가 링크입니다. 이 경로는 변경하지 않습니다.") }
            guard !resolved.path.hasPrefix(bank.path + "/"), !bank.path.hasPrefix(resolved.path + "/"), resolved.path != bank.path else { throw NativeFileTree.fail("스킬과 백업 폴더가 겹칩니다.") }
            // Preflight also detects every nested link before creating a transaction record.
            if let enumerator = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: nil) {
                while let url = enumerator.nextObject() as? URL {
                    guard try NativeFileTree.metadata(url).st_mode & S_IFMT != S_IFLNK else { throw NativeFileTree.fail("내부 심볼릭 링크가 있는 스킬은 아직 안전한 복구를 지원하지 않습니다.") }
                }
            }
            let id = UUID().uuidString.lowercased(), destination = bank.appendingPathComponent(id)
            try SecureLocalFileIO.ensurePrivateDirectory(destination)
            var record: [String: Any] = ["id": id, "name": row["name"]!, "original": path.path, "realPath": row["realPath"]!,
                "link": row["link"]!, "host": row["host"]!, "origin": row["origin"]!, "created": Date().timeIntervalSince1970,
                "state": "preparing", "error": "", "fingerprint": row["fingerprint"]!, "parentReal": parent.path, "scope": Self.scope]
            try save(record, destination)
            do {
                let content = destination.appendingPathComponent("content")
                try NativeFileTree.copy(path, to: content)
                record["contentHash"] = try NativeFileTree.fingerprint(content)
                record["originalHash"] = try NativeFileTree.fingerprint(path, follow: false)
                let settings = destination.appendingPathComponent("settings")
                try SecureLocalFileIO.ensurePrivateDirectory(settings)
                var configs: [[String: String]] = []
                for (index, relative) in Self.configs.enumerated() {
                    let source = home.appendingPathComponent(relative)
                    if NativeFileTree.exists(source), (try? NativeFileTree.metadata(NativeFileTree.resolved(source)).st_mode & S_IFMT) == S_IFREG {
                        let name = "\(index)-" + source.lastPathComponent
                        try SecureLocalFileIO.atomicWrite(NativeFileTree.read(source), to: settings.appendingPathComponent(name))
                        configs.append(["original": source.path, "backup": name, "realPath": try NativeFileTree.resolved(source).path])
                    }
                }
                record["settings"] = configs
                guard try NativeFileTree.fingerprint(path) == row["fingerprint"] as? String else { throw NativeFileTree.fail("백업 중 원본이 바뀌었습니다. 비활성화하지 않았습니다.") }
                let check = destination.appendingPathComponent("verification")
                try NativeFileTree.copy(path, to: check)
                guard try NativeFileTree.fingerprint(check) == record["contentHash"] as? String else { throw NativeFileTree.fail("백업 내용 검증 실패") }
                try FileManager.default.removeItem(at: check)
                record["state"] = "backedUp"; try save(record, destination)
                guard try NativeFileTree.fingerprint(path) == row["fingerprint"] as? String else { throw NativeFileTree.fail("이동 전 원본이 바뀌었습니다.") }
                let original = destination.appendingPathComponent("original")
                try rename(path, original)
                guard try NativeFileTree.fingerprint(original, follow: false) == record["originalHash"] as? String else {
                    try rename(original, path); throw NativeFileTree.fail("이동 중 원본이 바뀌어 원래 위치로 되돌렸습니다.")
                }
                record["state"] = "disabled"; try save(record, destination)
            } catch {
                record["state"] = NativeFileTree.exists(destination.appendingPathComponent("original")) ? "needsAttention" : "failed"
                record["error"] = error.localizedDescription
                try save(record, destination)
                throw NativeFileTree.fail("백업 " + id + "\n" + error.localizedDescription)
            }
        }
        return status()
    }
    func restore(_ request: [String: Any]) throws -> [String: Any] {
        try withLock {
            guard let id = request["id"] as? String, let uuid = UUID(uuidString: id) else { throw NativeFileTree.fail("백업 식별자가 올바르지 않습니다.") }
            let destination = bank.appendingPathComponent(uuid.uuidString.lowercased())
            var record = try backupRecord(destination)
            do {
                guard record["state"] as? String != "restored" else { throw NativeFileTree.fail("이미 복구된 백업입니다.") }
                let path = URL(fileURLWithPath: record["original"] as! String), parent = path.deletingLastPathComponent()
                if try !restoreFinished(record, destination) {
                    guard ["disabled", "backedUp", "needsAttention"].contains(record["state"] as? String ?? "") else { throw NativeFileTree.fail("비활성화가 완료되지 않은 백업은 복구할 수 없습니다.") }
                    guard record["originalHash"] is String, record["contentHash"] is String else { throw NativeFileTree.fail("백업 무결성 정보가 불완전합니다.") }
                    guard !NativeFileTree.exists(path) else { throw NativeFileTree.fail("복구 충돌: 원래 위치에 파일 또는 링크가 있습니다. 덮어쓰지 않았습니다.") }
                    guard isDirectory(parent), try NativeFileTree.resolved(parent).path == parent.path, parent.path == record["parentReal"] as? String else { throw NativeFileTree.fail("원래 상위 폴더가 없거나 경로가 바뀌었습니다.") }
                    let original = destination.appendingPathComponent("original")
                    guard try NativeFileTree.fingerprint(original, follow: false) == record["originalHash"] as? String,
                          try NativeFileTree.fingerprint(destination.appendingPathComponent("content")) == record["contentHash"] as? String else { throw NativeFileTree.fail("백업 내용의 무결성 검증 실패") }
                    if let link = record["link"] as? String, !link.isEmpty {
                        let target = link.hasPrefix("/") ? URL(fileURLWithPath: link) : parent.appendingPathComponent(link)
                        let check = destination.appendingPathComponent("restore-check-" + UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: check) }
                        try NativeFileTree.copy(target, to: check)
                        guard try NativeFileTree.fingerprint(check) == record["contentHash"] as? String else { throw NativeFileTree.fail("링크 대상 내용이 변경되었습니다. 자동 복구를 중단합니다.") }
                    }
                    record["restoreStarted"] = Date().timeIntervalSince1970; try save(record, destination)
                    try rename(original, path)
                    guard try NativeFileTree.fingerprint(path, follow: false) == record["originalHash"] as? String else {
                        try rename(path, original); throw NativeFileTree.fail("복구 중 보관 원본이 바뀌어 백업 위치로 되돌렸습니다.")
                    }
                }
                record["state"] = "restored"; record["error"] = ""; record["restored"] = Date().timeIntervalSince1970
            } catch { record["error"] = error.localizedDescription; try save(record, destination); throw error }
            try save(record, destination)
        }
        return status()
    }
    func compare(_ request: [String: Any]) throws -> [String: Any] {
        guard let ids = request["ids"] as? [String], ids.count == 2, ids[0] != ids[1] else { throw NativeFileTree.fail("비교할 서로 다른 설치 두 개를 선택하세요.") }
        let rows = inventory()
        let selected = ids.compactMap { id in rows.first { $0["id"] as? String == id } }
        guard selected.count == 2, selected.allSatisfy({ ($0["error"] as? String ?? "").isEmpty }) else { throw NativeFileTree.fail("비교할 설치 두 개를 선택하세요. 읽기 오류가 있는 파일은 비교할 수 없습니다.") }
        let texts = try selected.map { row -> String in
            let data = try NativeFileTree.read(URL(fileURLWithPath: row["filePath"] as! String))
            guard NativeFileTree.hash(data) == row["hash"] as? String, let text = String(data: data, encoding: .utf8) else { throw NativeFileTree.fail("비교 중 파일이 바뀌었습니다. 새로고침하세요.") }
            return text
        }
        if texts[0] == texts[1] { return ["diff": "SKILL.md 내용이 같습니다.", "same": true] }
        let a = texts[0].components(separatedBy: .newlines), b = texts[1].components(separatedBy: .newlines)
        // A complete replacement hunk is a valid unified diff and remains bounded by metadata limits.
        let diff = ["--- " + (selected[0]["filePath"] as! String), "+++ " + (selected[1]["filePath"] as! String),
                    "@@ -1,\(a.count) +1,\(b.count) @@"] + a.map { "-" + $0 } + b.map { "+" + $0 }
        return ["diff": diff.joined(separator: "\n"), "same": false]
    }
}
