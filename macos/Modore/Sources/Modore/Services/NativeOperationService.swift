import Darwin
import Foundation

/// Headless native operations share the app's signed binary and managed process lifecycle.
enum NativeOperationService {
    static let argument = "--native-operation"
    static func capture(_ operation: String, payload: Data, timeout: TimeInterval = 180,
                        maximumBytes: Int = 8_000_000, cleanupGrace: TimeInterval = 1, executable: URL? = nil) async throws -> Data {
        guard let executable = executable ?? Bundle.main.executableURL else { throw NativeFileTree.fail("앱 실행 파일을 찾지 못했습니다.") }
        let result = await LocalProcessRunner.capture(executable: executable.path,
            arguments: [argument, operation, "@pch-pinned:request"], currentDirectory: URL(fileURLWithPath: "/"),
            expectedSignedBundleURL: Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil,
            pinnedFiles: ["request": payload], timeout: timeout,
            maxOutputBytes: maximumBytes, forceKillAfterTermination: cleanupGrace, waitForCleanupOnStop: true)
        try Task.checkCancellation()
        let data = Data(result.output.utf8)
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let error = object["error"] as? String {
            throw NativeFileTree.fail(error)
        }
        guard result.succeeded else { throw NativeFileTree.fail("작업 응답을 확인하지 못했습니다. 기록을 새로 고쳐 확인하세요.") }
        return data
    }
    static func runAndExit(_ arguments: [String]) -> Never {
        umask(0o077)
        do {
            guard arguments.count == 4 else { throw NativeFileTree.fail("작업 요청이 올바르지 않습니다.") }
            // Request is an immutable, inherited descriptor owned by the spawning app.
            let data = try NativeFileTree.read(URL(fileURLWithPath: arguments[3]), limit: 8_000_000)
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeFileTree.fail("작업 요청이 객체 형식이 아닙니다.") }
            if arguments[2] == "session-backup" { NativeBackupCancellation.shared.install() }
            try printResult(perform(arguments[2], request: request))
            exit(0)
        } catch {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])) ?? Data("{}".utf8)
            FileHandle.standardOutput.write(data); exit(1)
        }
    }
    static func printResult(_ result: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes])
        guard data.count <= 8_000_000 else { throw NativeFileTree.fail("작업 응답 크기 제한 초과") }
        FileHandle.standardOutput.write(data)
    }
    static func perform(_ operation: String, request: [String: Any]) throws -> [String: Any] {
        switch operation {
        case "memory-diagnosis": return try MemoryDiagnosis.dictionary(MemoryDiagnosis.capture())
        case "skills": return try skills(request)
        case "ci": return try NativeCIWatch.invoke(request)
        case "resources": return try NativeWorkResources().invoke(request)
        case "build-artifacts": return try NativeBuildLifecycle().invoke(request)
        case "session-backup": return try NativeSessionBackup.dispatch(request)
        default: throw NativeFileTree.fail("지원하지 않는 작업입니다.")
        }
    }
    static func skills(_ request: [String: Any]) throws -> [String: Any] {
        let demo = request["demo"] as? Bool == true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = demo ? home.appendingPathComponent("Library/Application Support/Modore/skill-demo") : home
        if demo { try SecureLocalFileIO.ensurePrivateDirectory(root) }
        let manager = NativeSkillInventory(home: root)
        var action = request["action"] as? String ?? "status"
        if demo, action == "demo-create" {
            for (relative, host) in [(".codex/skills/sample-skill", "Codex"), (".claude/skills/sample-skill", "Claude")] {
                let folder = root.appendingPathComponent(relative)
                try SecureLocalFileIO.ensurePrivateDirectory(folder)
                let md = folder.appendingPathComponent("SKILL.md")
                if !NativeFileTree.exists(md) {
                    try SecureLocalFileIO.atomicWrite(Data(("---\nname: sample-skill\nversion: 1.0\ndescription: 격리된 검증 자료\n---\n" + host + " 전용 안내\n").utf8), to: md)
                }
            }
            action = "status"
        }
        switch action {
        case "status": return manager.status()
        case "disable": return try manager.disable(request)
        case "restore": return try manager.restore(request)
        case "compare": return try manager.compare(request)
        case "probe":
            guard !demo else { throw NativeFileTree.fail("검증 자료는 호스트에 등록되지 않습니다.") }
            var result = manager.status()
            let found = try NativeCodexRPC.read(home: home)
            var rows = result["items"] as? [[String: Any]] ?? []
            for index in rows.indices where rows[index]["host"] as? String == "Codex" {
                if let match = found.first(where: { $0["path"] as? String == rows[index]["filePath"] as? String }) {
                    let state = NativeSkillInventory.boolean(match["enabled"]).map { $0 ? "활성" : "비활성" } ?? "활성 미확인"
                    rows[index]["discovery"] = "Codex 발견 확인 · " + state
                }
            }
            result["items"] = rows
            var warnings = result["warnings"] as? [String] ?? []
            warnings.append("별도 Codex app-server의 홈 범위에서 \(found.count)개 발견 응답을 확인했습니다. 데스크톱의 원격 플러그인·프로젝트 범위·현재 세션 로드 상태를 증명하지 않습니다.")
            result["warnings"] = warnings
            return result
        default: throw NativeFileTree.fail("지원하지 않는 작업입니다.")
        }
    }
}

enum NativeCodexRPC {
    static func read(home: URL) throws -> [[String: Any]] {
        let result = try request("skills/list", params: ["cwds": [home.path], "forceReload": true], directory: home)
        return (result["data"] as? [[String: Any]] ?? []).flatMap { $0["skills"] as? [[String: Any]] ?? [] }
    }
    static func request(_ method: String, params: [String: Any], directory home: URL) throws -> [String: Any] {
        let choices = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                       "/Applications/Codex.app/Contents/Resources/codex"]
        guard let executable = choices.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw NativeFileTree.fail("설치된 Codex app-server 실행 파일을 찾지 못했습니다.") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["app-server"]
        process.currentDirectoryURL = home; process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var pending = Data()
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func receive(_ id: Int) throws -> [String: Any] {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while ProcessInfo.processInfo.systemUptime < deadline {
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]; pending.removeSubrange(...newline)
                    if let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], reply["id"] as? Int == id {
                        if let error = reply["error"] { throw NativeFileTree.fail(String(describing: error)) }
                        guard let result = reply["result"] as? [String: Any] else { throw NativeFileTree.fail("Codex 발견 응답 형식이 올바르지 않습니다.") }
                        return result
                    }
                }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&poller, 1, 100)
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { pending.append(contentsOf: buffer.prefix(count)) }
                else if count == 0 { break }
                else if errno != EAGAIN && errno != EINTR { break }
                guard pending.count <= 8_000_000 else { throw NativeFileTree.fail("Codex 발견 응답 크기 제한 초과") }
            }
            throw NativeFileTree.fail("Codex 발견 조회 시간 초과")
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "modore_diagnostics", "version": "1"], "capabilities": ["experimentalApi": true]]])
        _ = try receive(1); try send(["method": "initialized"])
        try send(["id": 2, "method": method, "params": params])
        return try receive(2)
    }
}
