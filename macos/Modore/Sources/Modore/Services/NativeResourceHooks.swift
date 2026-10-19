import Darwin
import Foundation
import TOMLDecoder

/// Bounded configuration metadata only; never executes a configured command.
enum NativeResourceHooks {
    private struct Config: Decodable {
        struct Features: Decodable { let hooks, codex_hooks: Bool? }
        struct Hooks: Decodable {
            struct State: Decodable { let enabled: Bool?; let trusted_hash: String? }
            let state: [String: State]?
        }
        let features: Features?
        let hooks: Hooks?
    }
    static func words(_ text: String) throws -> [String] {
        var result: [String] = [], current = "", quote: Character?, escaped = false, started = false
        for character in text {
            if escaped { current.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let delimiter = quote {
                if character == delimiter { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" { quote = character; started = true }
            else if character.isWhitespace { if started { result.append(current); current = ""; started = false } }
            else { current.append(character); started = true }
        }
        guard quote == nil, !escaped else { throw NativeFileTree.fail("연결 명령의 따옴표 형식이 올바르지 않습니다.") }
        if started { result.append(current) }; return result
    }
    static func stamp(_ home: URL) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for name in [".codex/config.toml", ".codex/hooks.json"] {
            let path = home.appendingPathComponent(name)
            result[name] = NativeFileTree.exists(path) ? try NativeFileTree.hash(NativeFileTree.read(path, limit: 1_048_576, nofollow: true)) : NSNull()
        }
        return result
    }
    static func status(_ state: [String: Any], home: URL, now: Double = Date().timeIntervalSince1970) -> [[String: Any]] {
        [("codex", ".codex/hooks.json"), ("claude", ".claude/settings.json")].map { provider, name in
            var configured = false, disabled = false, changed: Double = 0, readError: String?, simulator = false, trust = "unknown"
            let path = home.appendingPathComponent(name)
            do {
                if NativeFileTree.exists(path) {
                    let parent = path.deletingLastPathComponent(), fd = try NativeFileTree.directory(parent); close(fd)
                    let info = try NativeFileTree.metadata(path)
                    guard let config = try JSONSerialization.jsonObject(with: NativeFileTree.read(path, limit: 1_048_576, nofollow: true)) as? [String: Any] else { throw NativeFileTree.fail("연결 설정 형식 오류") }
                    changed = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
                    disabled = config["disableAllHooks"] as? Bool == true
                    guard let hooks = config["hooks"] as? [String: [[String: Any]]] else { throw NativeFileTree.fail("연결 이벤트 형식 오류") }
                    var handlers: [String: [[String: Any]]] = [:]
                    var diagnostics: [String] = []
                    var toml: Config?
                    if provider == "codex", NativeFileTree.exists(home.appendingPathComponent(".codex/config.toml")) {
                        let bytes = try NativeFileTree.read(home.appendingPathComponent(".codex/config.toml"), limit: 1_048_576, nofollow: true)
                        guard let text = String(data: bytes, encoding: .utf8) else { throw NativeFileTree.fail("UTF-8 설정이 아닙니다.") }
                        toml = try TOMLDecoder().decode(Config.self, from: text)
                        disabled = disabled || toml?.features?.hooks == false || toml?.features?.codex_hooks == false
                    }
                    for (event, groups) in hooks {
                        let snake = event.replacingOccurrences(of: #"(?<!^)(?=[A-Z])"#, with: "_", options: .regularExpression).lowercased()
                        for (gi, group) in groups.enumerated() {
                            guard let items = group["hooks"] as? [[String: Any]] else { throw NativeFileTree.fail("연결 핸들러 형식 오류") }
                            handlers[event, default: []] += items
                            for (hi, item) in items.enumerated() where provider == "codex" {
                                let words = try words(item["command"] as? String ?? "")
                                guard let executable = words.first, URL(fileURLWithPath: executable).lastPathComponent == "modore" else { continue }
                                if !FileManager.default.isExecutableFile(atPath: executable) { diagnostics.append("훅 실행 파일 없음: " + executable) }
                                let setting = toml?.hooks?.state?[path.path + ":" + snake + ":\(gi):\(hi)"]
                                if setting?.enabled == false { disabled = true }
                                if setting?.trusted_hash == nil { trust = "untrusted" }
                            }
                        }
                    }
                    func registered(_ event: String, _ verb: String) throws -> Bool {
                        try (handlers[event] ?? []).contains { item in
                            guard item["type"] as? String == "command" else { return false }
                            let args = try words(item["command"] as? String ?? "")
                            return args.count == 5 && URL(fileURLWithPath: args[0]).lastPathComponent == "modore" && Array(args.dropFirst()) == ["resources", verb, "--provider", provider]
                        }
                    }
                    configured = try registered("UserPromptSubmit", "hook") && registered("Stop", "hook")
                    simulator = try registered("PreToolUse", "guard")
                    if provider == "codex", let diagnosis = state["codexHookDiagnosis"] as? [String: Any],
                       let oldStamp = diagnosis["stamp"] as? [String: Any], NSDictionary(dictionary: oldStamp).isEqual(to: try stamp(home)),
                       let hs = diagnosis["hooks"] as? [[String: Any]], !hs.isEmpty {
                        trust = hs.allSatisfy { ["trusted", "managed"].contains($0["trustStatus"] as? String ?? "") } ? "trusted" : "untrusted"
                        disabled = disabled || hs.contains { $0["enabled"] as? Bool != true }
                    }
                    if !diagnostics.isEmpty { readError = diagnostics.joined(separator: "; ") }
                }
            } catch { readError = "연결 설정을 읽지 못했습니다." }
            let receipt = (state["hookObservations"] as? [String: [String: Any]])?[provider] ?? [:]
            let observed = (receipt["observedAt"] as? Double).flatMap { $0 > 0 && $0 <= now ? $0 : nil }
            let recent = configured && !disabled && readError == nil && observed.map { $0 >= changed && now - $0 <= 900 } == true && (provider != "codex" || trust == "trusted")
            return ["provider": provider, "configured": configured, "disabled": disabled, "lastObservedAt": observed as Any? ?? NSNull(),
                "lastEvent": receipt["event"] ?? NSNull(), "recentlyObserved": recent, "error": readError as Any? ?? NSNull(), "trustStatus": trust,
                "lastSession": receipt["session"] ?? NSNull(), "simulatorGuard": ["configured": simulator && !disabled, "hostEnforcementVerified": false,
                    "coverage": "실기기 접근·다른 시뮬레이터 조작을 지원 셸·MCP에서 검사합니다. 훅 신뢰 승인과 실제 호스트 검증이 필요합니다. 동적 코드·외부 앱 전체를 통제하는 OS 격리는 아닙니다."]]
        }
    }
}
