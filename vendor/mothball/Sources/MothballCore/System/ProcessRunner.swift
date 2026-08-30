import Darwin
import Foundation

public struct ProcessResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public var isSuccess: Bool { exitCode == 0 }
}

public enum ProcessError: Error, Sendable {
    case spawnFailed(underlying: Error)
    case timedOut(after: Duration)
}

/// Bounded subprocess execution in a private process group.
///
/// Git can start helpers through repository configuration. Killing only the
/// direct PID leaves those descendants alive and lets them keep stdout/stderr
/// open forever. This runner therefore creates a process group atomically in
/// `posix_spawn`, terminates the whole group on timeout/cancellation, and puts a
/// final deadline on pipe draining even if a child deliberately escapes it.
public enum ProcessRunner {
    private static let terminateToKillGrace: Duration = .seconds(5)
    private static let postTerminationDrainLimit: Duration = .seconds(2)

    public static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> ProcessResult {
        let controller = ProcessGroupController(
            terminateToKillGrace: terminateToKillGrace
        )

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            let spawned: SpawnedProcess
            do {
                spawned = try PosixSpawner.spawn(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory
                )
                controller.didSpawn(processGroupID: spawned.processID)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw ProcessError.spawnFailed(underlying: error)
            }

            let stdoutReader = BoundedPipeReader(descriptor: spawned.stdoutDescriptor)
            let stderrReader = BoundedPipeReader(descriptor: spawned.stderrDescriptor)
            let stdoutTask = Task { await stdoutReader.readAll() }
            let stderrTask = Task { await stderrReader.readAll() }

            let timeoutTask = Task<Bool, Never> {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return false
                }
                controller.requestTermination()
                return true
            }

            // Observe exit without reaping first. Keeping the leader as a
            // zombie pins its PID/PGID while we cancel any delayed escalation
            // and kill residual descendants. Reaping first would let a delayed
            // `kill(-pgid, ...)` hit an unrelated, newly reused process group.
            let didObserveExit = await waitForExitWithoutReaping(of: spawned.processID)
            timeoutTask.cancel()
            let didTimeOut = await timeoutTask.value
            let rawStatus: Int32
            if didObserveExit {
                controller.finishGroupBeforeReaping()
                rawStatus = await reap(spawned.processID)
            } else {
                // An unexpected ECHILD/error means the identity anchor is gone.
                // Cancel escalation instead of ever signalling a reusable PGID.
                controller.abandonLostLeader()
                rawStatus = Int32(127 << 8)
            }

            let drainStopper = Task<Void, Never> {
                try? await Task.sleep(for: postTerminationDrainLimit)
                guard !Task.isCancelled else { return }
                stdoutReader.stop()
                stderrReader.stop()
            }
            let stdoutBytes = await stdoutTask.value
            let stderrBytes = await stderrTask.value
            drainStopper.cancel()

            if Task.isCancelled { throw CancellationError() }
            if didTimeOut { throw ProcessError.timedOut(after: timeout) }

            return ProcessResult(
                stdout: String(decoding: stdoutBytes, as: UTF8.self),
                stderr: String(decoding: stderrBytes, as: UTF8.self),
                exitCode: decodedExitCode(rawStatus)
            )
        } onCancel: {
            controller.requestTermination()
        }
    }

    public static func run<E: Error>(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(10),
        wrapping: (ProcessError) -> E
    ) async throws -> ProcessResult {
        do {
            return try await run(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeout: timeout
            )
        } catch let error as ProcessError {
            throw wrapping(error)
        }
    }

    private static func waitForExitWithoutReaping(of processID: pid_t) async -> Bool {
        await Task.detached(priority: .utility) {
            var info = siginfo_t()
            var result: Int32
            repeat {
                result = Darwin.waitid(P_PID, id_t(processID), &info, WEXITED | WNOWAIT)
            } while result == -1 && errno == EINTR
            return result == 0
        }.value
    }

    private static func reap(_ processID: pid_t) async -> Int32 {
        await Task.detached(priority: .utility) {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = Darwin.waitpid(processID, &status, 0)
            } while result == -1 && errno == EINTR
            return result == processID ? status : Int32(127 << 8)
        }.value
    }

    private static func decodedExitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return 128 + signal
    }
}

private struct SpawnedProcess: Sendable {
    let processID: pid_t
    let stdoutDescriptor: Int32
    let stderrDescriptor: Int32
}

private enum PosixSpawner {
    static func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?
    ) throws -> SpawnedProcess {
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw posixError(EINVAL)
        }

        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&stdoutPipe) == 0 else { throw posixError(errno) }
        guard Darwin.pipe(&stderrPipe) == 0 else {
            Darwin.close(stdoutPipe[0]); Darwin.close(stdoutPipe[1])
            throw posixError(errno)
        }
        var didSpawn = false
        defer {
            Darwin.close(stdoutPipe[1])
            Darwin.close(stderrPipe[1])
            if !didSpawn {
                Darwin.close(stdoutPipe[0])
                Darwin.close(stderrPipe[0])
            }
        }
        try makeNonblockingAndCloseOnExec(stdoutPipe[0])
        try makeNonblockingAndCloseOnExec(stderrPipe[0])

        var actions: posix_spawn_file_actions_t? = nil
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]))
        try check(posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]))
        try check(posix_spawn_file_actions_addclose(&actions, stderrPipe[0]))
        try check(posix_spawn_file_actions_addclose(&actions, stderrPipe[1]))
        if let workingDirectory {
            guard workingDirectory.isFileURL, !workingDirectory.path.utf8.contains(0) else {
                throw posixError(EINVAL)
            }
            try workingDirectory.path.withCString { path in
                try check(posix_spawn_file_actions_addchdir_np(&actions, path))
            }
        }

        var attributes: posix_spawnattr_t? = nil
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT] {
            sigaddset(&defaultSignals, signal)
        }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        try check(posix_spawnattr_setsigmask(&attributes, &emptyMask))
        // A pgroup of zero means "use the spawned child's PID" and avoids the
        // race inherent in calling setpgid() from the parent after launch.
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        try check(posix_spawnattr_setflags(&attributes, flags))

        let command = [executable.path] + arguments
        let environment = cleanEnvironment()
        var processID: pid_t = 0
        let spawnStatus = try withMutableCStringArray(command) { argv in
            try withMutableCStringArray(environment) { envp in
                executable.path.withCString { path in
                    posix_spawn(&processID, path, &actions, &attributes, argv, envp)
                }
            }
        }
        try check(spawnStatus)
        didSpawn = true
        return SpawnedProcess(
            processID: processID,
            stdoutDescriptor: stdoutPipe[0],
            stderrDescriptor: stderrPipe[0]
        )
    }

    private static func cleanEnvironment() -> [String] {
        [
            "HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)",
            // bsdtar delegates zstd compression to an external executable on
            // macOS. Keep PATH deterministic, but include the two conventional
            // package-manager prefixes used by release and development hosts.
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8",
            "GIT_CONFIG_NOSYSTEM=1",
            "GIT_OPTIONAL_LOCKS=0",
            "GIT_TERMINAL_PROMPT=0",
        ]
    }

    private static func makeNonblockingAndCloseOnExec(_ descriptor: Int32) throws {
        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) >= 0 else {
            throw posixError(errno)
        }
        let statusFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) >= 0 else {
            throw posixError(errno)
        }
    }

    private static func check(_ status: Int32) throws {
        guard status == 0 else { throw posixError(status) }
    }

    private static func posixError(_ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> Result
    ) throws -> Result {
        var storage: [UnsafeMutablePointer<CChar>] = []
        storage.reserveCapacity(strings.count)
        for string in strings {
            guard let pointer = strdup(string) else { throw posixError(ENOMEM) }
            storage.append(pointer)
        }
        defer { storage.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = storage
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress)
        }
    }
}

private final class ProcessGroupController: @unchecked Sendable {
    private let terminateToKillGrace: Duration
    private let lock = NSLock()
    private let escalationQueue = DispatchQueue(label: "app.mothball.process-group")
    private var processGroupID: pid_t?
    private var terminationRequested = false
    private var escalationWorkItem: DispatchWorkItem?
    private var finished = false

    init(terminateToKillGrace: Duration) {
        self.terminateToKillGrace = terminateToKillGrace
    }

    func didSpawn(processGroupID: pid_t) {
        lock.lock()
        self.processGroupID = processGroupID
        let shouldStart = terminationRequested && !finished
        lock.unlock()
        if shouldStart { requestTermination() }
    }

    func requestTermination() {
        lock.lock()
        terminationRequested = true
        guard !finished,
              let group = processGroupID,
              escalationWorkItem == nil else {
            lock.unlock()
            return
        }
        _ = Darwin.kill(-group, SIGTERM)
        let workItem = DispatchWorkItem { [weak self] in
            self?.escalateIfCurrent(group)
        }
        escalationWorkItem = workItem
        lock.unlock()
        escalationQueue.asyncAfter(
            deadline: .now() + terminateToKillGrace.timeInterval,
            execute: workItem
        )
    }

    /// Called only after `waitid(..., WNOWAIT)` observed leader exit. The
    /// unreaped leader still owns the PGID, so this final group kill cannot
    /// target a reused identity. Legitimate helpers should have exited with
    /// their leader; any remainder is precisely the detached work this runner
    /// promises not to leak.
    func finishGroupBeforeReaping() {
        lock.lock()
        guard !finished, let group = processGroupID else {
            lock.unlock()
            return
        }
        escalationWorkItem?.cancel()
        escalationWorkItem = nil
        _ = Darwin.kill(-group, SIGKILL)
        processGroupID = nil
        finished = true
        lock.unlock()
    }

    /// If the child was reaped elsewhere, its numeric identity is unsafe to
    /// use. Drop every pending signal rather than guessing.
    func abandonLostLeader() {
        lock.lock()
        escalationWorkItem?.cancel()
        escalationWorkItem = nil
        processGroupID = nil
        finished = true
        lock.unlock()
    }

    private func escalateIfCurrent(_ group: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, processGroupID == group else { return }
        // The leader has not been reaped: either it is still running or is a
        // waitid-observed zombie, so this PGID cannot have been reused.
        _ = Darwin.kill(-group, SIGKILL)
    }
}

private final class BoundedPipeReader: @unchecked Sendable {
    private let capBytes: Int
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32, capBytes: Int = 4 * 1024 * 1024) {
        self.descriptor = descriptor
        self.capBytes = capBytes
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let openDescriptor = descriptor
        descriptor = -1
        if openDescriptor >= 0 { Darwin.close(openDescriptor) }
        lock.unlock()
    }

    func readAll() async -> Data {
        await Task.detached(priority: .utility) { [self] in
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            defer { stop() }

            while true {
                let current = descriptorSnapshot()
                guard current >= 0 else { return collected }

                var item = pollfd(fd: current, events: Int16(POLLIN | POLLHUP), revents: 0)
                let pollStatus = Darwin.poll(&item, 1, 100)
                if pollStatus < 0 {
                    if errno == EINTR { continue }
                    return collected
                }
                if pollStatus == 0 { continue }
                if item.revents & Int16(POLLERR | POLLNVAL) != 0 { return collected }

                while true {
                    let (count, readError) = readChunk(
                        from: current,
                        into: &buffer
                    )

                    if count > 0 {
                        let remaining = capBytes - collected.count
                        if remaining > 0 {
                            collected.append(contentsOf: buffer.prefix(min(remaining, count)))
                        }
                        continue
                    }
                    if count == -2 { return collected }
                    if count == 0 { return collected }
                    if readError == EINTR { continue }
                    if readError == EAGAIN || readError == EWOULDBLOCK { break }
                    return collected
                }
            }
        }.value
    }

    private func descriptorSnapshot() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    /// Returns -2 when `stop()` won the race before this read. Keeping the
    /// lock around the nonblocking syscall prevents a closed descriptor from
    /// being reused for an unrelated file between the identity check and read.
    private func readChunk(
        from expectedDescriptor: Int32,
        into buffer: inout [UInt8]
    ) -> (count: Int, error: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor == expectedDescriptor else { return (-2, 0) }
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(expectedDescriptor, bytes.baseAddress, bytes.count)
        }
        return (count, count < 0 ? errno : 0)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
