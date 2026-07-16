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
    static let safeSystemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    private static let allowedEnvironmentOverrides: Set<String> = [
        "ANDROID_HOME",
        "ANDROID_SDK_ROOT",
        "PCH_CONFIG_PATH",
        "PCH_PROJECT_DIR",
        "PCH_REDACT",
        "PCH_REPORT_OUTPUT",
        "PCH_SCAN",
        "PCH_PINNED_AUTORUNS_MODULE",
        "PCH_PINNED_CONFIG",
        "PCH_PINNED_CPU_MODULE",
        "PCH_PINNED_NETWORK_MODULE",
        "PCH_PINNED_SCANNER_HELPER",
        "PCH_PINNED_SECURITY_MODULE",
        "PCH_PINNED_STORAGE_MODULE",
        "PCH_PINNED_RULE_AUTORUNS",
        "PCH_PINNED_RULE_DEFENDER",
        "PCH_PINNED_RULE_INSTALLS",
        "PCH_PINNED_RULE_NETWORK",
        "PCH_PINNED_RULE_PROCESS",
        "PCH_PINNED_WHITELIST",
        "PCH_STORAGE_DU_TIMEOUT",
        "PCH_STORAGE_TOTAL_DU_BUDGET",
        "PCH_STORAGE_WATCH_SCRIPT",
        "PCH_STORAGE_WATCH_SHA256",
        "VT_API_KEY",
    ]

    static func stream(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        expectedCurrentDirectoryIdentity: FilesystemIdentity? = nil,
        expectedSignedBundleURL: URL? = nil,
        pinnedFiles: [String: Data] = [:],
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
                expectedCurrentDirectoryIdentity: expectedCurrentDirectoryIdentity,
                expectedSignedBundleURL: expectedSignedBundleURL,
                pinnedFiles: pinnedFiles,
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
        expectedCurrentDirectoryIdentity: FilesystemIdentity? = nil,
        expectedSignedBundleURL: URL? = nil,
        pinnedFiles: [String: Data] = [:],
        environment: [String: String] = [:],
        timeout: TimeInterval? = 60,
        maxOutputBytes: Int = 2_000_000
    ) async -> CapturedProcessResult {
        let session = ManagedProcessSession(
            configuration: SpawnConfiguration(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                expectedCurrentDirectoryIdentity: expectedCurrentDirectoryIdentity,
                expectedSignedBundleURL: expectedSignedBundleURL,
                pinnedFiles: pinnedFiles,
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

    static func sanitizedEnvironment(overrides: [String: String]) throws -> [String: String] {
        guard Set(overrides.keys).isSubset(of: allowedEnvironmentOverrides) else {
            throw invalidEnvironmentError()
        }
        let home = try trustedAccountHomeDirectory()
        let temporaryDirectory = try trustedUserTemporaryDirectory()
        var result = [
            "HOME": home,
            "PATH": safeSystemPath,
            "TMPDIR": temporaryDirectory,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        for (key, value) in overrides {
            guard !key.isEmpty,
                  !key.contains("="),
                  !key.utf8.contains(0),
                  !value.utf8.contains(0) else {
                throw invalidEnvironmentError()
            }
            result[key] = value
        }
        return result
    }

    private static func trustedAccountHomeDirectory() throws -> String {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let requestedSize = Darwin.sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = requestedSize > 0 && requestedSize <= 1_048_576
            ? Int(requestedSize) : 16_384
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let status = buffer.withUnsafeMutableBufferPointer { storage in
            Darwin.getpwuid_r(
                Darwin.geteuid(),
                &entry,
                storage.baseAddress,
                storage.count,
                &result
            )
        }
        guard status == 0, result != nil, let path = entry.pw_dir else {
            throw invalidEnvironmentError()
        }
        return try canonicalOwnedDirectory(String(cString: path))
    }

    private static func trustedUserTemporaryDirectory() throws -> String {
        let requiredSize = Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard requiredSize > 1, requiredSize <= 1_048_576 else {
            throw invalidEnvironmentError()
        }
        var buffer = [CChar](repeating: 0, count: requiredSize)
        let written = Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard written == requiredSize else { throw invalidEnvironmentError() }
        return try canonicalOwnedDirectory(String(cString: buffer))
    }

    private static func canonicalOwnedDirectory(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw invalidEnvironmentError()
        }
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var value = stat()
        let status = canonical.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return Int32(-1) }
            return Darwin.lstat(representation, &value)
        }
        let unsafeWriteBits = mode_t(S_IWGRP | S_IWOTH)
        guard status == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == Darwin.geteuid(),
              value.st_mode & unsafeWriteBits == 0 else {
            throw invalidEnvironmentError()
        }
        return canonical.path
    }

    private static func invalidEnvironmentError() -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EINVAL),
            userInfo: [NSLocalizedDescriptionKey: "안전한 프로세스 환경을 구성하지 못했습니다."]
        )
    }
}

private struct SpawnConfiguration: Sendable {
    let executable: String
    let arguments: [String]
    let currentDirectory: URL
    let expectedCurrentDirectoryIdentity: FilesystemIdentity?
    let expectedSignedBundleURL: URL?
    let pinnedFiles: [String: Data]
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
    private static let pinnedPlaceholderPrefix = "@pch-pinned:"

    static func spawn(_ configuration: SpawnConfiguration) throws -> SpawnedProcess {
        try validate(configuration)
        let directoryDescriptor = try openCurrentDirectory(configuration)
        defer { Darwin.close(directoryDescriptor) }
        if let bundleURL = configuration.expectedSignedBundleURL,
           !RuntimeWorkspace.codeAtURLMatchesRunningProcess(bundleURL) {
            throw posixError(EAUTH)
        }
        let openedPinnedFiles = try openPinnedFiles(configuration.pinnedFiles)
        defer { openedPinnedFiles.forEach { Darwin.close($0.parentDescriptor) } }
        var descriptors: [Int32] = [-1, -1]
        guard descriptors.withUnsafeMutableBufferPointer({ buffer in
            Darwin.pipe(buffer.baseAddress!)
        }) == 0 else {
            throw posixError(errno)
        }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        let pinnedDescriptors = try assignChildDescriptors(
            openedPinnedFiles,
            avoiding: Set(
                [directoryDescriptor, readDescriptor, writeDescriptor]
                    + openedPinnedFiles.map(\.parentDescriptor)
            )
        )
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
        try check(posix_spawn_file_actions_addfchdir_np(&actions, directoryDescriptor))
        try check(posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, readDescriptor))
        try check(posix_spawn_file_actions_addclose(&actions, writeDescriptor))
        for pinned in pinnedDescriptors {
            try check(posix_spawn_file_actions_adddup2(
                &actions,
                pinned.parentDescriptor,
                pinned.childDescriptor
            ))
            try check(posix_spawn_file_actions_addclose(&actions, pinned.parentDescriptor))
        }
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

        let pinnedPaths = Dictionary(
            uniqueKeysWithValues: pinnedDescriptors.map {
                ($0.name, "/dev/fd/\($0.childDescriptor)")
            }
        )
        let command = try ([configuration.executable] + configuration.arguments).map {
            try resolvePinnedPlaceholder($0, paths: pinnedPaths)
        }
        let environment = try LocalProcessRunner.sanitizedEnvironment(
            overrides: configuration.environment
        )
            .map { key, value in
                "\(key)=\(try resolvePinnedPlaceholder(value, paths: pinnedPaths))"
            }
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
        let validPinnedName = try! NSRegularExpression(pattern: "^[A-Za-z0-9_]{1,48}$")
        guard configuration.pinnedFiles.count <= 32,
              configuration.pinnedFiles.keys.allSatisfy({ name in
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                return validPinnedName.firstMatch(in: name, range: range) != nil
              }),
              configuration.pinnedFiles.values.reduce(0, { $0 + $1.count })
                <= 128 * 1_024 * 1_024 else {
            throw posixError(E2BIG)
        }
        _ = try LocalProcessRunner.sanitizedEnvironment(overrides: configuration.environment)
    }

    private struct OpenedPinnedFile {
        let name: String
        let parentDescriptor: Int32
    }

    private struct PinnedDescriptor {
        let name: String
        let parentDescriptor: Int32
        let childDescriptor: Int32
    }

    private static func openPinnedFiles(
        _ files: [String: Data]
    ) throws -> [OpenedPinnedFile] {
        guard !files.isEmpty else { return [] }
        let environment = try LocalProcessRunner.sanitizedEnvironment(overrides: [:])
        guard let temporaryDirectory = environment["TMPDIR"] else { throw posixError(EINVAL) }
        var result: [OpenedPinnedFile] = []
        do {
            for pair in files.sorted(by: { $0.key < $1.key }) {
                var template = Array(
                    "\(temporaryDirectory)/pch-pinned.XXXXXX".utf8CString
                )
                let descriptor = template.withUnsafeMutableBufferPointer {
                    Darwin.mkstemp($0.baseAddress!)
                }
                guard descriptor >= 0 else { throw posixError(errno) }
                let path = String(cString: template)
                do {
                    guard Darwin.fchmod(descriptor, 0o400) == 0 else {
                        throw posixError(errno)
                    }
                    try pair.value.withUnsafeBytes { bytes in
                        var written = 0
                        while written < bytes.count {
                            let count = Darwin.write(
                                descriptor,
                                bytes.baseAddress?.advanced(by: written),
                                bytes.count - written
                            )
                            if count < 0 {
                                if errno == EINTR { continue }
                                throw posixError(errno)
                            }
                            written += count
                        }
                    }
                    guard Darwin.fsync(descriptor) == 0 else {
                        throw posixError(errno)
                    }
                    let readDescriptor = path.withCString {
                        Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard readDescriptor >= 0 else { throw posixError(errno) }
                    var writtenMetadata = stat()
                    var readMetadata = stat()
                    guard Darwin.fstat(descriptor, &writtenMetadata) == 0,
                          Darwin.fstat(readDescriptor, &readMetadata) == 0,
                          writtenMetadata.st_dev == readMetadata.st_dev,
                          writtenMetadata.st_ino == readMetadata.st_ino,
                          Darwin.unlink(path) == 0 else {
                        let code = errno == 0 ? ESTALE : errno
                        Darwin.close(readDescriptor)
                        throw posixError(code)
                    }
                    Darwin.close(descriptor)
                    result.append(OpenedPinnedFile(
                        name: pair.key,
                        parentDescriptor: readDescriptor
                    ))
                } catch {
                    _ = Darwin.unlink(path)
                    Darwin.close(descriptor)
                    throw error
                }
            }
            return result
        } catch {
            result.forEach { Darwin.close($0.parentDescriptor) }
            throw error
        }
    }

    private static func assignChildDescriptors(
        _ files: [OpenedPinnedFile],
        avoiding forbiddenDescriptors: Set<Int32>
    ) throws -> [PinnedDescriptor] {
        let openMaximum = Darwin.sysconf(_SC_OPEN_MAX)
        guard openMaximum > 0 else { throw posixError(EMFILE) }
        var used = forbiddenDescriptors
        var candidate: Int32 = 100
        var result: [PinnedDescriptor] = []
        for file in files {
            while used.contains(candidate), Int64(candidate) < openMaximum {
                candidate += 1
            }
            guard Int64(candidate) < openMaximum else { throw posixError(EMFILE) }
            result.append(PinnedDescriptor(
                name: file.name,
                parentDescriptor: file.parentDescriptor,
                childDescriptor: candidate
            ))
            used.insert(candidate)
            candidate += 1
        }
        return result
    }

    private static func resolvePinnedPlaceholder(
        _ value: String,
        paths: [String: String]
    ) throws -> String {
        guard value.hasPrefix(pinnedPlaceholderPrefix) else { return value }
        let name = String(value.dropFirst(pinnedPlaceholderPrefix.count))
        guard let path = paths[name] else { throw posixError(ENOENT) }
        return path
    }

    private static func openCurrentDirectory(_ configuration: SpawnConfiguration) throws -> Int32 {
        let descriptor = configuration.currentDirectory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR else {
            let code = errno == 0 ? ENOTDIR : errno
            Darwin.close(descriptor)
            throw posixError(code)
        }
        if let expected = configuration.expectedCurrentDirectoryIdentity {
            let actual = FilesystemIdentity(
                device: UInt64(bitPattern: Int64(value.st_dev)),
                inode: UInt64(value.st_ino)
            )
            guard actual == expected else {
                Darwin.close(descriptor)
                throw posixError(ESTALE)
            }
        }
        return descriptor
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
