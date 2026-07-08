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

/// Async wrapper around `Foundation.Process`.
///
/// Three non-obvious things this gets right:
///
/// 1. **Pipe-buffer deadlock**: a child writing more than the kernel pipe
///    buffer (~64KB on macOS) blocks until the parent drains the pipe.
///    If the parent only reads after `waitUntilExit` returns, the child
///    hangs and so does the parent. We read both pipes concurrently with
///    waiting for exit using `async let`.
///
/// 2. **Timeout with SIGKILL escalation**: `Process` has no built-in
///    timeout. We launch a cancellable Task that sleeps for the timeout
///    duration, sends SIGTERM, waits a short grace, then sends SIGKILL
///    if the child still hasn't exited. Without the SIGKILL fallback a
///    SIGTERM-ignoring child (e.g. `git fetch` stuck in some network
///    states) would leave us in the `for await exitStream` loop forever.
///
/// 3. **Spawn-failure leak**: `async let` for the pipe readers is started
///    AFTER `process.run()` succeeds — kicking them off beforehand would
///    leave detached Tasks blocked on pipes with no writer if spawn
///    throws, since `Pipe` doesn't close on the synchronous failure path.
public enum ProcessRunner {
    /// Grace period between SIGTERM and SIGKILL when a timeout fires.
    /// Long enough for a well-behaved child to flush + exit, short enough
    /// that a misbehaving child can't stall the UI for the user.
    private static let terminateToKillGrace: Duration = .seconds(5)

    public static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Install the termination handler BEFORE process.run(). Foundation
        // fires the handler exactly once at termination time and does not
        // re-invoke it for handlers attached after the fact, so a process
        // that exits between run() and a later attachment would hang us.
        // AsyncStream lets us hand the handler a continuation that already
        // exists synchronously by the time we call run().
        let exitStream = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.spawnFailed(underlying: error)
        }

        // Pipe readers are started AFTER successful spawn so a spawn
        // failure can't strand detached Tasks on writerless pipes.
        async let stdoutBytes: Data = readAll(stdoutPipe.fileHandleForReading)
        async let stderrBytes: Data = readAll(stderrPipe.fileHandleForReading)

        // Returns true only if it actually fired terminate(); false if
        // it was cancelled because the process exited normally first.
        // SIGTERM first; if the child ignores it (some `git fetch` paths
        // do), escalate to SIGKILL after a grace period so we never hang.
        let timeoutTask = Task<Bool, Never> {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            guard process.isRunning else { return false }
            process.terminate()
            do {
                try await Task.sleep(for: terminateToKillGrace)
            } catch {
                return true
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return true
        }

        // Block until the stream finishes (no values are ever yielded;
        // finish() is the only signal). Yields control of the cooperative
        // pool, unlike process.waitUntilExit(). Bounded by the SIGKILL
        // escalation above — even an uncooperative child gets reaped.
        for await _ in exitStream { /* drained */ }

        // terminationHandler can fire a hair before NSTask flips its
        // internal "running" flag, and terminationStatus throws
        // NSInvalidArgumentException ("task still running") in that window.
        // The process is already dead here, so this returns immediately —
        // it only synchronizes NSTask's state, it does not wait on the child.
        process.waitUntilExit()

        // Cancel BEFORE awaiting value, otherwise we'd block until the
        // sleep naturally completes.
        timeoutTask.cancel()
        let didTimeOut = await timeoutTask.value

        let stdoutStr = String(data: await stdoutBytes, encoding: .utf8) ?? ""
        let stderrStr = String(data: await stderrBytes, encoding: .utf8) ?? ""

        if didTimeOut {
            throw ProcessError.timedOut(after: timeout)
        }

        return ProcessResult(
            stdout: stdoutStr,
            stderr: stderrStr,
            exitCode: process.terminationStatus
        )
    }

    /// Convenience overload that wraps `ProcessError` into a domain
    /// error before throwing. Eliminates the `do { try await run } catch
    /// let err as ProcessError { throw .process(err) }` boilerplate at
    /// every call site that has its own error type.
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
        } catch let err as ProcessError {
            throw wrapping(err)
        }
    }

    /// Reads up to `capBytes` and discards anything beyond. Always
    /// drains the pipe to EOF so the child never blocks on a full
    /// pipe buffer, but caps memory regardless of how chatty stderr
    /// gets — `tar` warnings or `git` progress can otherwise balloon
    /// to hundreds of MB during a long-running operation.
    private static func readAll(_ handle: FileHandle, capBytes: Int = 4 * 1024 * 1024) async -> Data {
        await Task.detached {
            var collected = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return collected }   // EOF
                let remaining = capBytes - collected.count
                if remaining > 0 {
                    collected.append(remaining < chunk.count ? chunk.prefix(remaining) : chunk)
                }
                // else: pipe still drains to keep child unblocked, output discarded
            }
        }.value
    }
}
