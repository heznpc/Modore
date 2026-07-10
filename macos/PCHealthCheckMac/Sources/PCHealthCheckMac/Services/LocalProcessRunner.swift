import Foundation

struct CapturedProcessResult: Sendable {
    let status: Int32
    let output: String
}

enum LocalProcessRunner {
    static func stream(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String] = [:],
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = configuredProcess(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: environment
            )
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let runState = ProcessRunState()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                emit(handle.availableData, to: onOutput)
            }
            process.terminationHandler = { terminated in
                pipe.fileHandleForReading.readabilityHandler = nil
                emit(pipe.fileHandleForReading.readDataToEndOfFile(), to: onOutput)
                runState.resume(continuation, returning: terminated.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                onOutput("실행 실패: \(executable) \(arguments.joined(separator: " "))")
                onOutput(error.localizedDescription)
                runState.resume(continuation, returning: -1)
            }
        }
    }

    static func capture(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) async -> CapturedProcessResult {
        await withCheckedContinuation { continuation in
            let process = configuredProcess(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: [:]
            )
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let runState = CaptureProcessRunState()

            do {
                try process.run()
                let session = CapturedProcessSession(
                    process: process,
                    pipe: pipe,
                    continuation: continuation,
                    runState: runState
                )
                DispatchQueue.global(qos: .utility).async {
                    session.drainAndResume()
                }
            } catch {
                runState.resume(
                    continuation,
                    returning: CapturedProcessResult(status: -1, output: error.localizedDescription)
                )
            }
        }
    }

    private static func configuredProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var mergedEnvironment = ProcessInfo.processInfo.environment
        environment.forEach { mergedEnvironment[$0.key] = $0.value }
        process.environment = mergedEnvironment
        return process
    }

    private static func emit(_ data: Data, to receiver: @escaping @Sendable (String) -> Void) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        text.split(whereSeparator: \.isNewline).forEach { receiver(String($0)) }
    }
}

private final class CapturedProcessSession: @unchecked Sendable {
    private let process: Process
    private let pipe: Pipe
    private let continuation: CheckedContinuation<CapturedProcessResult, Never>
    private let runState: CaptureProcessRunState

    init(
        process: Process,
        pipe: Pipe,
        continuation: CheckedContinuation<CapturedProcessResult, Never>,
        runState: CaptureProcessRunState
    ) {
        self.process = process
        self.pipe = pipe
        self.continuation = continuation
        self.runState = runState
    }

    func drainAndResume() {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        runState.resume(
            continuation,
            returning: CapturedProcessResult(status: process.terminationStatus, output: output)
        )
    }
}

private final class CaptureProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<CapturedProcessResult, Never>,
        returning value: CapturedProcessResult
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }
}
