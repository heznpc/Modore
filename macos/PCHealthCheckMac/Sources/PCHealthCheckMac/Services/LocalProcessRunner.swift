import Darwin
import Foundation

enum ProcessEndState: Sendable, Equatable {
    case exited
    case timedOut
    case cancelled
    case outputLimit
    case launchFailed
}

struct CapturedProcessResult: Sendable {
    let status: Int32
    let output: String
    let endState: ProcessEndState
    let outputTruncated: Bool

    var succeeded: Bool {
        status == 0 && endState == .exited && !outputTruncated
    }
}

enum LocalProcessRunner {
    static let timeoutStatus: Int32 = 124
    static let outputLimitStatus: Int32 = 125
    static let cancellationStatus: Int32 = 130

    static func stream(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String] = [:],
        timeout: TimeInterval? = 180,
        maxOutputBytes: Int = 2_000_000,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let session = ManagedProcessSession(
            configuration: SpawnConfiguration(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: environment
            ),
            outputMode: .stream(onOutput),
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
        let result = await withTaskCancellationHandler {
            await session.run()
        } onCancel: {
            session.cancel()
        }
        return result.status
    }

    static func capture(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String] = [:],
        timeout: TimeInterval? = 60,
        maxOutputBytes: Int = 2_000_000
    ) async -> CapturedProcessResult {
        let session = ManagedProcessSession(
            configuration: SpawnConfiguration(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: environment
            ),
            outputMode: .capture,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
        return await withTaskCancellationHandler {
            await session.run()
        } onCancel: {
            session.cancel()
        }
    }
}

private struct SpawnConfiguration: Sendable {
    let executable: String
    let arguments: [String]
    let currentDirectory: URL
    let environment: [String: String]
}

private struct SpawnedProcess: Sendable {
    let pid: pid_t
    let outputFileDescriptor: Int32
}

private enum ProcessOutputMode: Sendable {
    case capture
    case stream(@Sendable (String) -> Void)
}

private final class ManagedProcessSession: @unchecked Sendable {
    private static let pollIntervalMilliseconds: Int32 = 100
    private static let forceKillDelay: TimeInterval = 1
    private static let stopCompletionLimit: TimeInterval = 3
    private static let postTerminationDrainLimit: TimeInterval = 2

    private let configuration: SpawnConfiguration
    private let outputMode: ProcessOutputMode
    private let timeout: TimeInterval?
    private let maxOutputBytes: Int
    private let lock = NSLock()
    private let terminationSignal = DispatchSemaphore(value: 0)

    private var continuation: CheckedContinuation<CapturedProcessResult, Never>?
    private var processID: pid_t?
    private var didLaunch = false
    private var didFinish = false
    private var observedTerminationStatus: Int32?
    private var terminationObservedAt: UInt64?
    private var stopReason: ProcessEndState?
    private var stopRequestedAt: UInt64?
    private var groupTerminationScheduled = false
    private var deadlineWork: DispatchWorkItem?
    private var forceKillWork: DispatchWorkItem?

    init(
        configuration: SpawnConfiguration,
        outputMode: ProcessOutputMode,
        timeout: TimeInterval?,
        maxOutputBytes: Int
    ) {
        self.configuration = configuration
        self.outputMode = outputMode
        self.timeout = timeout
        self.maxOutputBytes = max(1, maxOutputBytes)
    }

    func run() async -> CapturedProcessResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let shouldCancelBeforeLaunch = stopReason == .cancelled
            lock.unlock()

            guard !shouldCancelBeforeLaunch else {
                finish(
                    status: LocalProcessRunner.cancellationStatus,
                    output: diagnostic(for: .cancelled),
                    truncated: false,
                    state: .cancelled
                )
                return
            }

            do {
                let spawned = try PosixProcessSpawner.spawn(configuration)
                lock.lock()
                processID = spawned.pid
                didLaunch = true
                let hasPendingStop = stopReason != nil
                lock.unlock()

                observeTermination(of: spawned.pid)
                scheduleDeadline()
                if hasPendingStop {
                    scheduleGroupTerminationIfNeeded()
                }
                DispatchQueue.global(qos: .utility).async { [self] in
                    drainAndFinish(fileDescriptor: spawned.outputFileDescriptor)
                }
            } catch {
                emitIfStreaming("실행 실패: \(error.localizedDescription)")
                finish(
                    status: -1,
                    output: error.localizedDescription,
                    truncated: false,
                    state: .launchFailed
                )
            }
        }
    }

    func cancel() {
        requestStop(.cancelled)
    }

    private func observeTermination(of pid: pid_t) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var rawStatus: Int32 = 0
            var result: pid_t
            repeat {
                result = Darwin.waitpid(pid, &rawStatus, 0)
            } while result == -1 && errno == EINTR

            let status = result == pid ? Self.exitStatus(from: rawStatus) : -1
            self?.recordTermination(status: status)
        }
    }

    private func scheduleDeadline() {
        guard let timeout, timeout > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.requestStop(.timedOut)
        }
        lock.lock()
        guard !didFinish, stopReason == nil else {
            lock.unlock()
            return
        }
        deadlineWork = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func drainAndFinish(fileDescriptor: Int32) {
        defer { Darwin.close(fileDescriptor) }
        var captured = Data()
        var framer = UTF8LineFramer()
        var byteCount = 0
        var truncated = false
        var pipeFinished = false
        var descriptor = pollfd(
            fd: fileDescriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

        while true {
            if !pipeFinished {
                descriptor.revents = 0
                let pollResult = Darwin.poll(&descriptor, 1, Self.pollIntervalMilliseconds)
                if pollResult > 0 {
                    for _ in 0..<8 {
                        let count = buffer.withUnsafeMutableBytes { bytes in
                            Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
                        }
                        if count > 0 {
                            let data = Data(buffer.prefix(Int(count)))
                            let remaining = maxOutputBytes - byteCount
                            if remaining > 0 {
                                let accepted = data.prefix(remaining)
                                byteCount += accepted.count
                                switch outputMode {
                                case .capture:
                                    captured.append(accepted)
                                case .stream(let receiver):
                                    framer.append(Data(accepted), receiver: receiver)
                                }
                            }
                            if data.count > remaining, !truncated {
                                truncated = true
                                requestStop(.outputLimit)
                            }
                            continue
                        }
                        if count == 0 {
                            pipeFinished = true
                        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                            pipeFinished = true
                        }
                        break
                    }
                } else if pollResult < 0, errno != EINTR {
                    pipeFinished = true
                }
            } else {
                _ = terminationSignal.wait(timeout: .now() + .milliseconds(100))
            }

            let snapshot = lifecycleSnapshot()
            if pipeFinished, snapshot.terminationStatus != nil {
                // A descendant can close its copy of stdout/stderr and keep
                // running after the root exits. Do not cancel the scheduled
                // SIGKILL until the private process group is actually empty.
                if let processID = snapshot.processID,
                   snapshot.groupTerminationScheduled,
                   Self.processGroupExists(processID) {
                    _ = terminationSignal.wait(timeout: .now() + .milliseconds(100))
                } else {
                    break
                }
            }
            if let stopRequestedAt = snapshot.stopRequestedAt,
               elapsedTime(since: stopRequestedAt) >= Self.stopCompletionLimit {
                break
            }
            if let terminationObservedAt = snapshot.terminationObservedAt,
               elapsedTime(since: terminationObservedAt) >= Self.postTerminationDrainLimit {
                break
            }
        }

        if case .stream(let receiver) = outputMode {
            framer.finish(receiver: receiver)
        }

        let snapshot = lifecycleSnapshot()
        let state = snapshot.stopReason ?? (truncated ? .outputLimit : .exited)
        let status = terminalStatus(state: state, observedStatus: snapshot.terminationStatus)
        var output = String(decoding: captured, as: UTF8.self)
        if state != .exited {
            let note = diagnostic(for: state)
            if case .stream = outputMode {
                emitIfStreaming(note)
            } else {
                if !output.isEmpty, !output.hasSuffix("\n") { output.append("\n") }
                output.append(note)
            }
        }
        finish(status: status, output: output, truncated: truncated, state: state)
    }

    private func recordTermination(status: Int32) {
        lock.lock()
        guard observedTerminationStatus == nil else {
            lock.unlock()
            return
        }
        observedTerminationStatus = status
        terminationObservedAt = monotonicNow()
        lock.unlock()
        terminationSignal.signal()

        // The root command may exit while background descendants still own the
        // output pipe. The process group belongs exclusively to this session.
        scheduleGroupTerminationIfNeeded()
    }

    private func requestStop(_ reason: ProcessEndState) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        if stopReason == nil {
            stopReason = reason
            stopRequestedAt = monotonicNow()
        }
        lock.unlock()
        scheduleGroupTerminationIfNeeded()
    }

    private func scheduleGroupTerminationIfNeeded() {
        let pid: pid_t
        let forceWork: DispatchWorkItem
        lock.lock()
        guard didLaunch,
              !didFinish,
              !groupTerminationScheduled,
              let processID else {
            lock.unlock()
            return
        }
        groupTerminationScheduled = true
        pid = processID
        forceWork = DispatchWorkItem { [weak self] in
            self?.forceStopGroupIfNeeded(pid: pid)
        }
        forceKillWork = forceWork
        lock.unlock()

        _ = Darwin.kill(-pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.forceKillDelay,
            execute: forceWork
        )
    }

    private func forceStopGroupIfNeeded(pid: pid_t) {
        lock.lock()
        let alreadyFinished = didFinish
        lock.unlock()
        guard !alreadyFinished else { return }
        _ = Darwin.kill(-pid, SIGKILL)
    }

    private func lifecycleSnapshot() -> (
        terminationStatus: Int32?,
        terminationObservedAt: UInt64?,
        stopReason: ProcessEndState?,
        stopRequestedAt: UInt64?,
        processID: pid_t?,
        groupTerminationScheduled: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            observedTerminationStatus,
            terminationObservedAt,
            stopReason,
            stopRequestedAt,
            processID,
            groupTerminationScheduled
        )
    }

    private func terminalStatus(state: ProcessEndState, observedStatus: Int32?) -> Int32 {
        switch state {
        case .exited: return observedStatus ?? -1
        case .timedOut: return LocalProcessRunner.timeoutStatus
        case .cancelled: return LocalProcessRunner.cancellationStatus
        case .outputLimit: return LocalProcessRunner.outputLimitStatus
        case .launchFailed: return -1
        }
    }

    private func emitIfStreaming(_ line: String) {
        if case .stream(let receiver) = outputMode {
            receiver(line)
        }
    }

    private func finish(
        status: Int32,
        output: String,
        truncated: Bool,
        state: ProcessEndState
    ) {
        lock.lock()
        guard !didFinish, let continuation else {
            lock.unlock()
            return
        }
        didFinish = true
        self.continuation = nil
        let deadlineWork = self.deadlineWork
        let forceKillWork = self.forceKillWork
        self.deadlineWork = nil
        self.forceKillWork = nil
        lock.unlock()

        deadlineWork?.cancel()
        forceKillWork?.cancel()
        continuation.resume(
            returning: CapturedProcessResult(
                status: status,
                output: output,
                endState: state,
                outputTruncated: truncated
            )
        )
    }

    private func diagnostic(for state: ProcessEndState) -> String {
        switch state {
        case .exited: return ""
        case .timedOut: return "실행 시간이 제한을 초과해 중단했습니다."
        case .cancelled: return "요청이 취소되어 실행을 중단했습니다."
        case .outputLimit: return "출력 크기가 안전 상한을 초과해 실행을 중단했습니다."
        case .launchFailed: return "프로세스를 시작하지 못했습니다."
        }
    }

    private func monotonicNow() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private func elapsedTime(since start: UInt64) -> TimeInterval {
        let now = monotonicNow()
        guard now >= start else { return 0 }
        return TimeInterval(now - start) / 1_000_000_000
    }

    private static func exitStatus(from rawStatus: Int32) -> Int32 {
        let terminatingSignal = rawStatus & 0x7f
        if terminatingSignal == 0 {
            return (rawStatus >> 8) & 0xff
        }
        return 128 + terminatingSignal
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        errno = 0
        if Darwin.kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }
}

private enum PosixProcessSpawner {
    static func spawn(_ configuration: SpawnConfiguration) throws -> SpawnedProcess {
        try validate(configuration)
        var descriptors: [Int32] = [-1, -1]
        guard descriptors.withUnsafeMutableBufferPointer({ buffer in
            Darwin.pipe(buffer.baseAddress!)
        }) == 0 else {
            throw posixError(errno)
        }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        var didSpawn = false
        defer {
            if !didSpawn {
                Darwin.close(readDescriptor)
            }
            Darwin.close(writeDescriptor)
        }

        try setFlag(FD_CLOEXEC, on: readDescriptor, command: F_SETFD)
        let currentFlags = Darwin.fcntl(readDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw posixError(errno) }
        try setFlag(currentFlags | O_NONBLOCK, on: readDescriptor, command: F_SETFL)

        var actions: posix_spawn_file_actions_t? = nil
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try configuration.currentDirectory.path.withCString { path in
            try check(posix_spawn_file_actions_addchdir_np(&actions, path))
        }
        try check(posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, readDescriptor))
        try check(posix_spawn_file_actions_addclose(&actions, writeDescriptor))
        try "/dev/null".withCString { path in
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDONLY, 0))
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
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        try check(posix_spawnattr_setflags(&attributes, flags))

        let command = [configuration.executable] + configuration.arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        configuration.environment.forEach { mergedEnvironment[$0.key] = $0.value }
        let environment = mergedEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var pid: pid_t = 0
        let spawnResult = try withMutableCStringArray(command) { arguments in
            try withMutableCStringArray(environment) { environment in
                configuration.executable.withCString { executable in
                    posix_spawn(
                        &pid,
                        executable,
                        &actions,
                        &attributes,
                        arguments,
                        environment
                    )
                }
            }
        }
        try check(spawnResult)
        didSpawn = true
        return SpawnedProcess(pid: pid, outputFileDescriptor: readDescriptor)
    }

    private static func validate(_ configuration: SpawnConfiguration) throws {
        let values = [configuration.executable, configuration.currentDirectory.path]
            + configuration.arguments
            + configuration.environment.flatMap { [$0.key, $0.value] }
        guard values.allSatisfy({ !$0.utf8.contains(0) }),
              configuration.executable.hasPrefix("/"),
              configuration.currentDirectory.isFileURL,
              configuration.environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "프로세스 실행 인수가 올바르지 않습니다."]
            )
        }
    }

    private static func setFlag(_ value: Int32, on descriptor: Int32, command: Int32) throws {
        guard Darwin.fcntl(descriptor, command, value) != -1 else {
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

private struct UTF8LineFramer {
    private var pending = Data()

    mutating func append(_ data: Data, receiver: @Sendable (String) -> Void) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[..<newline]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            receiver(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(...newline)
        }
    }

    mutating func finish(receiver: @Sendable (String) -> Void) {
        guard !pending.isEmpty else { return }
        if pending.last == 0x0D { pending.removeLast() }
        receiver(String(decoding: pending, as: UTF8.self))
        pending.removeAll(keepingCapacity: false)
    }
}
