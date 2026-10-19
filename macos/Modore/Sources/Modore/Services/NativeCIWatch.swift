import Darwin
import Foundation

/// The CI journal has a native collector. Remote operations remain explicit GETs.
enum NativeCIWatch {
    typealias API = (String, Bool) throws -> Any
    static let failed: Set<String> = ["failure", "timed_out", "startup_failure", "action_required"]
    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func replace(_ text: String, _ pattern: String, _ replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    static func digest(_ value: Any) throws -> String {
        let text = try NativeFileTree.pythonJSON(value, sortedKeys: true)
        // Python's CI IDs used ensure_ascii=True. Keep existing incident/event IDs stable.
        let ascii = text.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            if value < 128 { return String(scalar) }
            if value <= 0xffff { return String(format: "\\u%04x", value) }
            let code = value - 0x10000
            return String(format: "\\u%04x\\u%04x", 0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff))
        }.joined()
        return String(NativeFileTree.hash(ascii).prefix(24))
    }
    static func scrub(_ text: String) -> String {
        var text = replace(text, #"\x1b\[[0-?]*[ -/]*[@-~]"#, "")
        text = replace(text, #"(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)"#, "[token]")
        text = replace(text, #"(?i)(authorization\s*[:=]\s*|(?:token|password|secret|api[_-]?key)\s*[:=]\s*)\S+"#, "$1[redacted]")
        text = replace(text, #"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}"#, "[email]")
        text = replace(text, #"(?:/Users/|/home/)[^\s/:]+"#, "/[user]")
        text = replace(text, #"https?://[^\s)]+"#, "[url]")
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }).prefix(2000))
    }
    static func slug(_ value: String) throws -> String {
        guard value.range(of: #"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z"#, options: .regularExpression) != nil,
              !value.contains("..") else { throw NativeFileTree.fail("Use a GitHub repository in owner/name form") }
        return value.lowercased()
    }
    static func projectRepository(_ path: String) -> String? {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path),
              let result = try? NativeCommand.run("/usr/bin/git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path, "remote", "get-url", "origin"], timeout: 3, limit: 8192), result.status == 0 else { return nil }
        let remote = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\A(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
              let range = Range(match.range(at: 1), in: remote) else { return nil }
        return try? slug(String(remote[range]))
    }
    static func order(_ run: [String: Any]) -> [Any] {
        [run["created_at"] as? String ?? "", run["run_number"] as? Int64 ?? 0, run["run_attempt"] as? Int64 ?? 1]
    }
    static func compare(_ a: Any?, _ b: Any?) -> Int {
        guard let a = a as? [Any], let b = b as? [Any], a.count == 3, b.count == 3 else { return 0 }
        let lhs = a[0] as? String ?? "", rhs = b[0] as? String ?? ""
        if lhs != rhs { return lhs < rhs ? -1 : 1 }
        for index in 1...2 {
            let lhs = (a[index] as? NSNumber)?.int64Value ?? 0, rhs = (b[index] as? NSNumber)?.int64Value ?? 0
            if lhs != rhs { return lhs < rhs ? -1 : 1 }
        }
        return 0
    }
    static func series(_ repo: String, _ run: [String: Any]) throws -> String {
        try digest([repo.lowercased(), run["workflow_id"] ?? run["path"] ?? NSNull(), run["head_branch"] ?? NSNull(),
                    run["event"] ?? NSNull(), (run["head_repository"] as? [String: Any])?["id"] ?? NSNull()])
    }
    static func evidence(api: API, repo: String, run: [String: Any]) throws -> [String: Any] {
        let id = (run["id"] as? NSNumber)?.stringValue ?? "", attempt = (run["run_attempt"] as? NSNumber)?.stringValue ?? "1"
        guard let response = try api("repos/\(repo)/actions/runs/\(id)/attempts/\(attempt)/jobs?per_page=100", false) as? [String: Any],
              let jobs = response["jobs"] as? [[String: Any]] else { throw NativeFileTree.fail("invalid GitHub job response") }
        var steps: [String] = [], excerpts: [String] = []
        for job in jobs where failed.contains(job["conclusion"] as? String ?? "") {
            let broken = (job["steps"] as? [[String: Any]] ?? []).filter { failed.contains($0["conclusion"] as? String ?? "") }.compactMap { $0["name"] as? String }
            steps.append(scrub((job["name"] as? String ?? "") + ": " + (broken.isEmpty ? [job["conclusion"] as? String ?? "failure"] : broken).joined(separator: ", ")))
            guard excerpts.count < 4, let jobID = job["id"] as? NSNumber,
                  let log = try? api("repos/\(repo)/actions/jobs/\(jobID.stringValue)/logs", true) as? String else { continue }
            let lines = log.components(separatedBy: .newlines).map { replace($0, #"^\d{4}-\d\d-\d\dT\S+\s+"#, "").trimmingCharacters(in: .whitespaces) }
            let relevant = lines.prefix { !$0.contains("##[error]Process completed with exit code") }
            let matched = relevant.filter {
                $0.range(of: #"(?i)(?:##\[error\]|\berror:|\bFAILED\b|AssertionError|Error:|coverage too low|npm ERR!)"#, options: .regularExpression) != nil
                    && $0.range(of: #"(?i)(?:\b0 failed\b|\b0 failures\b|^\+|^\d+\s+(?:failed|passed|skipped)|process completed with exit code)"#, options: .regularExpression) == nil
            }
            excerpts += matched.suffix(4).map(scrub)
        }
        if steps.isEmpty { steps = [scrub(run["conclusion"] as? String ?? "failure")] }
        var unique = Set<String>(); excerpts = Array(excerpts.filter { unique.insert($0).inserted }.prefix(6))
        let named = excerpts.filter { $0.hasPrefix("FAILED ") && $0.contains("::") }.map { $0.components(separatedBy: " - ")[0] }
        let normalized = (named.isEmpty ? excerpts : named).map { original -> String in
            var text = replace(original, #"\b[0-9a-f]{7,40}\b"#, "<hash>")
            text = replace(text, #"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b"#, "<id>")
            text = replace(text, #":\d+(?::\d+)?"#, ":<line>")
            return replace(text, #"\b\d+\.\d+\b"#, "<number>")
        }
        return ["steps": steps, "evidence": excerpts.isEmpty ? "step" : "log", "diagnosticVersion": 1,
                "excerpt": excerpts.joined(separator: "\n"), "signature": try digest([steps, normalized]), "stepKey": try digest(steps)]
    }
    static func collect(api: API, repo: String, prior: [[String: Any]]) throws -> [String: Any] {
        guard let data = try api("repos/\(repo)/actions/runs?per_page=50", false) as? [String: Any],
              let runs = data["workflow_runs"] as? [[String: Any]] else { throw NativeFileTree.fail("GitHub returned an invalid run list") }
        var lanes: [String: [[String: Any]]] = [:], laneOrder: [String] = []
        for run in runs.sorted(by: { compare(order($0), order($1)) > 0 }) {
            let key = try series(repo, run)
            if lanes[key] == nil { laneOrder.append(key) }
            lanes[key, default: []].append(run)
        }
        var openPRs: [[String: Any]]?
        if lanes.values.contains(where: { $0.first?["event"] as? String == "pull_request" }),
           let response = try? api("repos/\(repo)/pulls?state=open&per_page=100", false) as? [[String: Any]], response.count < 100 { openPRs = response }
        var samples: [[String: Any]] = [], budget = 8
        for series in laneOrder {
            let history = lanes[series]!, run = history[0]
            guard let id = run["id"] as? NSNumber else { throw NativeFileTree.fail("GitHub run has no identity") }
            let attempt = id.stringValue + ":" + ((run["run_attempt"] as? NSNumber)?.stringValue ?? "1")
            var sample: [String: Any] = ["series": series, "repo": repo, "workflow": scrub(run["name"] as? String ?? "CI"),
                "branch": scrub(run["head_branch"] as? String ?? ""), "event": run["event"] ?? "", "runId": id,
                "attempt": attempt, "order": order(run), "url": "https://github.com/\(repo)/actions/runs/\(id.stringValue)",
                "sha": run["head_sha"] ?? "", "status": run["status"] ?? NSNull(), "conclusion": run["conclusion"] ?? NSNull(), "observedAt": now(), "streak": 0]
            if run["event"] as? String == "pull_request", let openPRs {
                let numbers = Set((run["pull_requests"] as? [[String: Any]] ?? []).compactMap { $0["number"] as? Int64 })
                let origin = (run["head_repository"] as? [String: Any])?["id"] as? Int64
                if !numbers.isEmpty || origin != nil {
                    sample["activePR"] = openPRs.contains {
                        let head = $0["head"] as? [String: Any] ?? [:]
                        return ($0["number"] as? Int64).map { numbers.contains($0) } == true
                            || (head["ref"] as? String == run["head_branch"] as? String && (head["repo"] as? [String: Any])?["id"] as? Int64 == origin)
                    }
                }
            }
            sample["streak"] = history.prefix { $0["status"] as? String == "completed" && failed.contains($0["conclusion"] as? String ?? "") }.count
            if sample["status"] as? String == "completed", failed.contains(sample["conclusion"] as? String ?? ""), sample["activePR"] as? Bool != false {
                if let cached = prior.first(where: { $0["series"] as? String == series && $0["attempt"] as? String == attempt && $0["diagnosticVersion"] as? Int == 1 }) {
                    for key in ["steps", "evidence", "excerpt", "signature", "stepKey", "diagnosticVersion"] { sample[key] = cached[key] }
                } else if budget > 0 {
                    sample.merge(try evidence(api: api, repo: repo, run: run)) { _, new in new }; budget -= 1
                } else {
                    sample.merge(["steps": [sample["workflow"]!], "evidence": "workflow", "excerpt": "", "signature": try digest(sample["workflow"]!), "stepKey": try digest(sample["workflow"]!)]) { _, new in new }
                }
            }
            samples.append(sample)
        }
        return ["repo": repo, "observedAt": now(), "runsRead": runs.count,
            "limited": (data["total_count"] as? Int ?? 0) > runs.count, "error": NSNull(), "samples": samples]
    }
    static func reconcile(_ initial: [String: Any], collections: [[String: Any]], notify: Bool = false,
                          timestamp: String? = nil) throws -> [String: Any] {
        var state = initial, issues: [String: [String: Any]] = [:]
        for issue in state["incidents"] as? [[String: Any]] ?? [] {
            guard let id = issue["id"] as? String else { throw NativeFileTree.fail("CI incident has no identity") }; issues[id] = issue
        }
        var events = state["events"] as? [[String: Any]] ?? [], eventIDs = Set(events.compactMap { $0["id"] as? String })
        let baseline = state["initialized"] as? Bool ?? false, stamp = timestamp ?? now()
        func event(_ issue: [String: Any], _ kind: String, _ attempt: Any) throws {
            guard notify && baseline, let iid = issue["id"] as? String else { return }
            let id = try digest([iid, kind, attempt])
            if eventIDs.insert(id).inserted { events.append(["id": id, "incidentId": iid, "kind": kind, "repo": issue["repo"]!]) }
        }
        for collection in collections where collection["error"] is NSNull || collection["error"] == nil {
            let samples = collection["samples"] as? [[String: Any]] ?? []
            let visible = Set(samples.compactMap { $0["series"] as? String })
            for id in Array(issues.keys) {
                if issues[id]?["repo"] as? String == collection["repo"] as? String, issues[id]?["state"] as? String == "open", !visible.contains(issues[id]?["series"] as? String ?? "") { issues[id]?["tracking"] = "not_observed" }
            }
            for original in samples {
                var sample = original
                let related = issues.keys.filter { issues[$0]?["series"] as? String == sample["series"] as? String && issues[$0]?["state"] as? String == "open" }
                if sample["activePR"] as? Bool == false {
                    for id in related { issues[id]?["state"] = "inactive"; issues[id]?["tracking"] = "closed_pr" }; continue
                }
                let status = sample["status"] as? String ?? "", conclusion = sample["conclusion"] as? String ?? ""
                guard status == "completed", failed.contains(conclusion) || conclusion == "success" else {
                    for id in related { issues[id]?["tracking"] = status == "completed" ? conclusion : status }; continue
                }
                if conclusion == "success" {
                    for id in related where compare(sample["order"], issues[id]?["order"]) > 0 {
                        issues[id]?.merge(["state": "recovered", "recoveredAt": stamp, "recoveryURL": sample["url"]!, "recoveryOrder": sample["order"]!, "tracking": "success"]) { _, new in new }
                        try event(issues[id]!, "recovered", sample["attempt"]!)
                    }
                    continue
                }
                if sample["evidence"] as? String != "log", let prior = related.compactMap({ issues[$0] }).first(where: { $0["stepKey"] as? String == sample["stepKey"] as? String }) {
                    for key in ["signature", "excerpt", "evidence"] { sample[key] = prior[key] }
                }
                guard let series = sample["series"], let signature = sample["signature"] else { throw NativeFileTree.fail("incomplete CI failure evidence") }
                let iid = try digest([series, signature]), old = issues[iid]
                if let recovery = old?["recoveryOrder"], compare(sample["order"], recovery) <= 0 { continue }
                if old != nil, compare(sample["order"], old?["order"]) < 0 { continue }
                let fresh = old == nil || old?["state"] as? String != "open"
                for id in related where id != iid && compare(sample["order"], issues[id]?["order"]) >= 0 {
                    issues[id]?.merge(["state": "changed", "tracking": "changed", "changedAt": stamp]) { _, new in new }
                }
                var count = old?["observedFailures"] as? Int ?? 0
                if old == nil || old?["attempt"] as? String != sample["attempt"] as? String { count += 1 }
                sample.merge(["id": iid, "state": "open", "tracking": "failure", "firstSeen": old?["firstSeen"] ?? stamp, "lastSeen": stamp, "observedFailures": count]) { _, new in new }
                issues[iid] = sample
                if fresh { try event(sample, "failure", sample["attempt"]!) }
            }
        }
        state["incidents"] = Array(issues.values.sorted { ($0["lastSeen"] as? String ?? "") > ($1["lastSeen"] as? String ?? "") }.prefix(250))
        state["events"] = Array(events.filter {
            guard let id = $0["incidentId"] as? String, let issue = issues[id] else { return false }
            return ($0["kind"] as? String == "failure" && issue["state"] as? String == "open") || ($0["kind"] as? String == "recovered" && issue["state"] as? String == "recovered")
        }.suffix(100))
        state["initialized"] = baseline || collections.contains { $0["error"] is NSNull || $0["error"] == nil }
        state["checkedAt"] = stamp
        state["repositories"] = collections.map { $0.filter { $0.key != "samples" } }
        return state
    }
    static func empty() -> [String: Any] {
        ["version": 1, "initialized": false, "checkedAt": NSNull(), "incidents": [], "events": [], "repositories": [], "projects": [:], "tracked": [], "discoveryError": NSNull()]
    }
}
