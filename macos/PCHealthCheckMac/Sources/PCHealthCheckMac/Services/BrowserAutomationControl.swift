import Darwin
import Foundation

enum BrowserAutomationControl {
    private static let processTableArguments = [
        "-axo", "pid=,ppid=,etime=,rss=,command=",
    ]

    static func preview(
        signal: RuntimeSignal
    ) async throws -> BrowserAutomationStopPreview {
        let processes = try await readProcessTable()
        guard let process = processes.first(where: { $0.pid == signal.pid }) else {
            throw BrowserAutomationStopError.targetGone
        }
        async let executablePathValue = readProcessValue(pid: process.pid, field: "comm=")
        async let startTimeValue = readProcessValue(pid: process.pid, field: "lstart=")
        let executablePath = try await executablePathValue
        let startTime = try await startTimeValue
        let classification = classify(
            executablePath: executablePath,
            command: process.command
        )
        guard classification.canStop else {
            throw BrowserAutomationStopError.protectedProfile
        }
        let members = processTree(rootPID: process.pid, processes: processes)
        return BrowserAutomationStopPreview(
            id: UUID(),
            identity: BrowserAutomationProcessIdentity(
                pid: process.pid,
                parentPid: process.parentPid,
                startTime: startTime,
                executablePath: executablePath,
                command: process.command
            ),
            elapsed: process.elapsed,
            channel: classification.channel,
            profile: classification.profile,
            controller: controllerLabel(parentPID: process.parentPid, processes: processes),
            rootMemoryKB: process.memoryKB,
            treeMemoryKB: members.reduce(0) { $0 + $1.memoryKB },
            processCount: members.count
        )
    }

    static func stop(_ preview: BrowserAutomationStopPreview) async throws {
        let processes = try await readProcessTable()
        guard let current = processes.first(where: { $0.pid == preview.pid }) else {
            throw BrowserAutomationStopError.targetGone
        }
        async let executablePathValue = readProcessValue(pid: current.pid, field: "comm=")
        async let startTimeValue = readProcessValue(pid: current.pid, field: "lstart=")
        let executablePath = try await executablePathValue
        let startTime = try await startTimeValue
        let currentIdentity = BrowserAutomationProcessIdentity(
            pid: current.pid,
            parentPid: current.parentPid,
            startTime: startTime,
            executablePath: executablePath,
            command: current.command
        )
        guard currentIdentity == preview.identity else {
            throw BrowserAutomationStopError.targetChanged
        }
        guard classify(executablePath: executablePath, command: current.command).canStop else {
            throw BrowserAutomationStopError.protectedProfile
        }
        guard current.pid > 1,
              current.pid <= Int(Int32.max),
              Darwin.kill(pid_t(current.pid), SIGTERM) == 0 else {
            throw BrowserAutomationStopError.signalFailed
        }

        for _ in 0..<50 {
            if !processExists(pid: current.pid) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BrowserAutomationStopError.stillRunning
    }

    static func parseProcessTable(_ text: String) -> [BrowserAutomationProcess] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                maxSplits: 4,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 5,
                  let pid = Int(fields[0]),
                  let parentPid = Int(fields[1]),
                  let memoryKB = Int(fields[3]),
                  pid > 0,
                  parentPid >= 0,
                  memoryKB >= 0 else { return nil }
            return BrowserAutomationProcess(
                pid: pid,
                parentPid: parentPid,
                elapsed: String(fields[2]),
                memoryKB: memoryKB,
                command: String(fields[4])
            )
        }
    }

    static func classify(
        executablePath: String,
        command: String
    ) -> BrowserAutomationClassification {
        let isHelper = command.contains("Google Chrome Helper")
            || command.contains("Chromium Helper")
            || command.contains(" --type=")
        let isSystemChrome = executablePath
            == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let isChromiumBinary = executablePath.hasSuffix("/Chromium.app/Contents/MacOS/Chromium")
        // Only Chromium bundled under the Playwright cache is automation-only.
        // A user-installed /Applications/Chromium.app is a daily-driver browser
        // and must not be treated as a disposable isolated instance.
        let isBundledAutomationChromium = isChromiumBinary
            && executablePath.contains("/ms-playwright/")
        let isGenericChromium = isChromiumBinary && !isBundledAutomationChromium
        let isIsolatedChrome = executablePath.hasSuffix(
            "/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        ) || isBundledAutomationChromium
        let hasAutomationMarker = command.contains("playwright_chromiumdev_profile")
            || command.contains("--remote-debugging-pipe")
            || command.contains("--remote-debugging-port")
            || command.contains("--no-startup-window")
            || command.contains("--headless")
        let profile: String
        let hasDisposableProfilePath = [
            "--user-data-dir=/tmp/",
            "--user-data-dir=/private/tmp/",
            "--user-data-dir=/var/folders/",
            "--user-data-dir=/private/var/folders/",
            "--user-data-dir=\"/tmp/",
            "--user-data-dir=\"/private/tmp/",
            "--user-data-dir=\"/var/folders/",
            "--user-data-dir=\"/private/var/folders/",
        ].contains(where: command.contains)
        if command.contains("playwright_chromiumdev_profile") || hasDisposableProfilePath {
            profile = "temporary"
        } else if command.contains("--user-data-dir=") {
            profile = "custom"
        } else {
            profile = "default"
        }
        let channel = isIsolatedChrome ? "isolated" : (isSystemChrome ? "system" : "unknown")
        let profileIsDisposable = profile == "temporary"
        // Automation-only browsers may be stopped outright. A real browser
        // (system Chrome, or a user-installed generic Chromium) is only
        // stoppable when it is clearly running a disposable throwaway profile,
        // never on its default profile.
        let canStop = !isHelper
            && hasAutomationMarker
            && (isIsolatedChrome
                || ((isSystemChrome || isGenericChromium) && profileIsDisposable))
        return BrowserAutomationClassification(
            channel: channel,
            profile: profile,
            canStop: canStop
        )
    }

    static func processTree(
        rootPID: Int,
        processes: [BrowserAutomationProcess]
    ) -> [BrowserAutomationProcess] {
        let byParent = Dictionary(grouping: processes, by: \.parentPid)
        var pending = [rootPID]
        var visited = Set<Int>()
        var result: [BrowserAutomationProcess] = []
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        while let pid = pending.popLast(), visited.insert(pid).inserted {
            if let process = byPID[pid] { result.append(process) }
            pending.append(contentsOf: (byParent[pid] ?? []).map(\.pid))
        }
        return result
    }

    static func controllerLabel(
        parentPID: Int,
        processes: [BrowserAutomationProcess]
    ) -> String {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var currentPID = parentPID
        var fallback = "other local process"
        for _ in 0..<8 {
            guard currentPID > 1, let process = byPID[currentPID] else { break }
            let command = process.command
            if command.contains("Codex.app")
                || command.contains("/codex")
                || command.contains("SkyComputerUseClient") {
                return "Codex"
            }
            if command.contains("Claude.app")
                || command.contains("/claude")
                || command.contains("claude-code") {
                return "Claude"
            }
            if command.contains("ChatGPT.app")
                || command.contains("/ChatGPT")
                || command.contains("com.openai.chat") {
                return "ChatGPT"
            }
            if command.contains("playwright") || command.contains("node") {
                fallback = "Playwright/Node"
            } else if command.contains("python"), fallback == "other local process" {
                fallback = "Python automation"
            }
            currentPID = process.parentPid
        }
        return fallback
    }

    private static func readProcessTable() async throws -> [BrowserAutomationProcess] {
        let result = await LocalProcessRunner.capture(
            executable: "/bin/ps",
            arguments: processTableArguments,
            currentDirectory: URL(fileURLWithPath: "/", isDirectory: true),
            timeout: 5,
            maxOutputBytes: 4_000_000
        )
        guard result.succeeded else { throw BrowserAutomationStopError.unavailable }
        return parseProcessTable(result.output)
    }

    private static func readProcessValue(
        pid: Int,
        field: String
    ) async throws -> String {
        guard pid > 1, pid <= Int(Int32.max) else {
            throw BrowserAutomationStopError.targetChanged
        }
        let result = await LocalProcessRunner.capture(
            executable: "/bin/ps",
            arguments: ["-p", String(pid), "-o", field],
            currentDirectory: URL(fileURLWithPath: "/", isDirectory: true),
            timeout: 5,
            maxOutputBytes: 4_096
        )
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !value.isEmpty else {
            throw BrowserAutomationStopError.targetGone
        }
        return value
    }

    private static func processExists(pid: Int) -> Bool {
        errno = 0
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
