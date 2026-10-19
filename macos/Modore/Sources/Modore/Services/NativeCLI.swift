import Darwin
import Foundation

/// The checkout command translates arguments only. App and CLI execute the
/// same operations and keep the same journals and safety checks.
enum NativeCLI {
    static let argument = "--native-cli"
    static func parse(_ arguments: [String]) throws -> (String, [String: Any]) {
        var words = Array(arguments.dropFirst(2))
        guard !words.isEmpty else { throw NativeFileTree.fail("native command required") }
        let command = words.removeFirst()
        let action = words.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "status"
        if words.first == action { words.removeFirst() }
        func flags(_ values: Set<String>, switches: Set<String> = [], repeated: Set<String> = []) throws -> [String: Any] {
            var result: [String: Any] = [:], index = 0
            while index < words.count {
                let key = words[index]
                guard values.contains(key) || switches.contains(key), result[key] == nil || repeated.contains(key) else { throw NativeFileTree.fail("unsupported or repeated option: " + key) }
                if switches.contains(key) { result[key] = true; index += 1 }
                else {
                    guard index + 1 < words.count, !words[index + 1].hasPrefix("--"), !words[index + 1].isEmpty else { throw NativeFileTree.fail("option requires a value: " + key) }
                    if repeated.contains(key) { result[key] = (result[key] as? [String] ?? []) + [words[index + 1]] }
                    else { result[key] = words[index + 1] }
                    index += 2
                }
            }
            return result
        }
        switch command {
        case "ci":
            guard ["status", "refresh"].contains(action) else { throw NativeFileTree.fail("ci requires status or refresh") }
            let options = try flags(["--repo", "--project"], switches: ["--discover"], repeated: ["--repo", "--project"])
            return ("ci", ["action": action, "repos": options["--repo"] ?? [], "projects": options["--project"] ?? [], "discover": options["--discover"] ?? false])
        case "sessions":
            let operations = ["backup", "backup-verify", "backup-restore", "backup-recovery", "backup-resume"]
            guard operations.contains(action), let source = words.first, !source.hasPrefix("--") else { throw NativeFileTree.fail("session backup operation and source required") }
            words.removeFirst()
            let options = try flags(["--out"], switches: ["--include-sensitive"])
            if ["backup", "backup-restore", "backup-recovery", "backup-resume"].contains(action), options["--out"] == nil { throw NativeFileTree.fail("--out is required") }
            if action == "backup", options["--include-sensitive"] as? Bool != true { throw NativeFileTree.fail("raw backups require --include-sensitive") }
            if action != "backup", options["--include-sensitive"] != nil { throw NativeFileTree.fail("--include-sensitive applies only to backup creation") }
            if action == "backup-verify", options["--out"] != nil { throw NativeFileTree.fail("verification does not accept --out") }
            var args = [action, source]
            if let output = options["--out"] as? String { args += ["--out", output] }
            if options["--include-sensitive"] as? Bool == true { args += ["--include-sensitive"] }
            return ("session-backup", ["arguments": args])
        case "skills":
            guard ["status", "compare", "disable", "restore"].contains(action) else { throw NativeFileTree.fail("unknown skill operation") }
            let options = try flags(["--id", "--fingerprint"], switches: ["--demo"], repeated: ["--id"])
            let ids = options["--id"] as? [String] ?? []
            guard (action == "status" && ids.isEmpty) || (action == "compare" && ids.count == 2) || (["disable", "restore"].contains(action) && ids.count == 1) else { throw NativeFileTree.fail("select the required installation or backup IDs") }
            if action == "disable", options["--fingerprint"] == nil { throw NativeFileTree.fail("disable requires the displayed fingerprint") }
            if action != "disable", options["--fingerprint"] != nil { throw NativeFileTree.fail("fingerprint applies only to disable") }
            var request: [String: Any] = ["action": action, "demo": options["--demo"] ?? false]
            if action == "compare" { request["ids"] = ids } else if let id = ids.first { request["id"] = id }
            request["fingerprint"] = options["--fingerprint"]
            return ("skills", request)
        case "resources":
            guard ["status", "diagnose-hooks", "acquire", "claim", "bind", "unbind", "boot", "shutdown", "prefer", "eject"].contains(action) else { throw NativeFileTree.fail("unsupported native resource action") }
            let options = try flags(["--id", "--runtime", "--deviceType", "--session", "--project", "--fingerprint", "--provider"], switches: ["--override"])
            var request: [String: Any] = ["action": action]
            for (key, value) in options { request[String(key.dropFirst(2))] = value }
            return ("resources", request)
        default: throw NativeFileTree.fail("unknown native command")
        }
    }
    static func runAndExit(_ arguments: [String]) -> Never {
        umask(0o077)
        do {
            let (operation, request) = try parse(arguments)
            if operation == "session-backup" { NativeBackupCancellation.shared.install() }
            try NativeOperationService.printResult(NativeOperationService.perform(operation, request: request))
            exit(0)
        } catch {
            try? NativeOperationService.printResult(["error": error.localizedDescription]); exit(1)
        }
    }
}
