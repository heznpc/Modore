import Darwin
import Foundation

extension NativeCIWatch {
    /// Immutable API configuration. Every call owns its command and buffers.
    final class GitHub: @unchecked Sendable {
        let executable: String
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        init() throws {
            guard let path = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw NativeFileTree.fail("GitHub CLI (gh) is not installed") }
            executable = path
        }
        func get(_ endpoint: String, raw: Bool) throws -> Any {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw NativeFileTree.fail("CI collection time limit reached; retry to refresh remaining repositories") }
            let result = try NativeCommand.run(executable, ["api", "--hostname", "github.com", "--method", "GET", endpoint], timeout: min(20, remaining),
                environment: ["GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat", "GIT_TERMINAL_PROMPT": "0"])
            guard result.status == 0 else { throw NativeFileTree.fail("GitHub query failed; check gh authentication and repository access") }
            return raw ? result.text : try JSONSerialization.jsonObject(with: result.output)
        }
    }
    /// Prior JSON is immutable, API reads are independent, and only the result
    /// array is mutated under the lock. At most four repositories are collected.
    private final class Collection: @unchecked Sendable {
        let api: API
        let prior: [[String: Any]]
        private let lock = NSLock()
        private var results: [Int: [String: Any]] = [:]
        init(api: @escaping API, prior: [[String: Any]]) { self.api = api; self.prior = prior }
        func collect(_ repo: String, at index: Int) {
            let result: [String: Any]
            do { result = try NativeCIWatch.collect(api: api, repo: repo, prior: prior) }
            catch { result = ["repo": repo, "observedAt": NSNull(), "runsRead": 0, "limited": false, "error": scrub(error.localizedDescription), "samples": []] }
            lock.lock(); results[index] = result; lock.unlock()
        }
        func ordered(_ count: Int) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }; return (0..<count).compactMap { results[$0] }
        }
    }
    static func refresh(_ initial: [String: Any], request: [String: Any], api: @escaping API) throws -> [String: Any] {
        var state = initial, projects = state["projects"] as? [String: [String]] ?? [:]
        var normalized: [String: [String]] = [:]
        for (key, value) in projects { normalized[try slug(key)] = value }
        projects = normalized
        var repos = try (request["repos"] as? [String] ?? []).map(slug)
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        for path in (request["projects"] as? [String] ?? []).prefix(80) {
            if ProcessInfo.processInfo.systemUptime > deadline { break }
            if let repo = projectRepository(path) {
                if !(projects[repo] ?? []).contains(path) { projects[repo] = Array(((projects[repo] ?? []) + [path]).suffix(8)) }
                repos.append(repo)
            }
        }
        repos += try (state["tracked"] as? [String] ?? []).map(slug)
        var discoveryError: Any = NSNull()
        if request["discover"] as? Bool == true {
            do {
                guard let notifications = try api("notifications?all=true&per_page=100", false) as? [[String: Any]] else { throw NativeFileTree.fail("Invalid notification response") }
                for item in notifications where (item["subject"] as? [String: Any])?["type"] as? String == "CheckSuite" {
                    guard let name = (item["repository"] as? [String: Any])?["full_name"] as? String else { throw NativeFileTree.fail("Invalid notification repository") }
                    repos.append(try slug(name))
                }
            } catch { discoveryError = scrub(error.localizedDescription) }
        }
        var seen = Set<String>(); repos = repos.filter { seen.insert($0).inserted }
        state["repositoryLimitReached"] = repos.count > 24; repos = Array(repos.prefix(24))
        let collector = Collection(api: api, prior: state["incidents"] as? [[String: Any]] ?? [])
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 4
        for (index, repo) in repos.enumerated() { queue.addOperation { collector.collect(repo, at: index) } }
        queue.waitUntilAllOperationsAreFinished()
        state["projects"] = projects; state["tracked"] = repos; state["discoveryError"] = discoveryError
        return try reconcile(state, collections: collector.ordered(repos.count), notify: request["notify"] as? Bool == true)
    }
    static func invoke(_ request: [String: Any], root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Modore/ci"),
                       api: API? = nil) throws -> [String: Any] {
        let path = root.appendingPathComponent("state.json")
        func read() throws -> [String: Any] {
            guard NativeFileTree.exists(path) else { return empty() }
            let data = try SecureLocalFileIO.boundedRead(from: path, maximumBytes: 4_000_000, requireCurrentOwner: true)
            guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any], state["version"] as? Int == 1 else { throw NativeFileTree.fail("Unsupported CI state version") }
            _ = try JSONDecoder().decode(CISnapshot.self, from: data)
            for issue in state["incidents"] as? [[String: Any]] ?? [] {
                guard issue["series"] is String, issue["attempt"] is String, issue["order"] is [Any], issue["signature"] is String, issue["stepKey"] is String else { throw NativeFileTree.fail("Incomplete CI incident metadata") }
            }
            return state
        }
        let action = request["action"] as? String ?? "status"
        if action == "status" { return try read() }
        try SecureLocalFileIO.ensurePrivateDirectory(root)
        let lock = open(root.appendingPathComponent("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw NativeFileTree.fail("CI state lock unavailable") }; defer { close(lock) }
        var metadata = stat()
        guard fstat(lock, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NativeFileTree.fail("CI state is busy or unsafe") }
        var state = try read()
        if action == "refresh" {
            let get: API
            if let api { get = api }
            else { let github = try GitHub(); get = { try github.get($0, raw: $1) } }
            state = try refresh(state, request: request, api: get)
        } else if action == "ack" {
            let ids = Set(request["ids"] as? [String] ?? [])
            state["events"] = (state["events"] as? [[String: Any]] ?? []).filter { !ids.contains($0["id"] as? String ?? "") }
        } else { throw NativeFileTree.fail("Unknown CI action") }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.withoutEscapingSlashes])
        guard data.count <= 4_000_000 else { throw NativeFileTree.fail("CI state exceeds the storage limit") }
        try SecureLocalFileIO.atomicWrite(data, to: path)
        return state
    }
}
