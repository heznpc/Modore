import Darwin
import Foundation

/// Bounded native command adapter. Callers use exact executable paths and argument arrays.
enum NativeCommand {
    struct Result: Sendable {
        let status: Int32
        let output: Data
        let error: Data
        var text: String { String(decoding: output, as: UTF8.self) }
        var errorText: String { String(decoding: error, as: UTF8.self) }
    }
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil,
                    input: Data? = nil, timeout: TimeInterval = 20, limit: Int = 4_000_000,
                    environment: [String: String] = [:]) throws -> Result {
        guard timeout.isFinite, timeout > 0, limit >= 0, executable.hasPrefix("/"), !executable.utf8.contains(0), arguments.allSatisfy({ !$0.utf8.contains(0) }) else { throw NativeFileTree.fail("invalid native command") }
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output; process.standardError = error
        var variables = ProcessInfo.processInfo.environment
        for (key, value) in environment { variables[key] = value }
        variables["PATH"] = LocalProcessRunner.safeSystemPath
        process.environment = variables
        var inputFD: Int32 = -1
        if let input {
            let template = FileManager.default.temporaryDirectory.appendingPathComponent("modore-command-XXXXXX").path
            var name = Array(template.utf8CString)
            inputFD = mkstemp(&name)
            guard inputFD >= 0 else { throw NativeFileTree.fail("cannot create private command input") }
            _ = unlink(name)
            do { try NativeFileTree.write(input, descriptor: inputFD); _ = lseek(inputFD, 0, SEEK_SET) }
            catch { close(inputFD); throw error }
            process.standardInput = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
        } else { process.standardInput = FileHandle.nullDevice }
        defer { if inputFD >= 0 { close(inputFD) } }
        try process.run()
        defer {
            if process.isRunning { process.terminate(); usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close(); try? error.fileHandleForReading.close()
        }
        try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
        let outFD = output.fileHandleForReading.fileDescriptor, errFD = error.fileHandleForReading.fileDescriptor
        for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var active = Set([outFD, errFD]), stdout = Data(), stderr = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !active.isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFileTree.fail("native command timed out") }
            var pollers = active.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            _ = poll(&pollers, nfds_t(pollers.count), 50)
            for poller in pollers where poller.revents != 0 {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(poller.fd, &buffer, buffer.count)
                if count == 0 { active.remove(poller.fd) }
                else if count > 0 {
                    if poller.fd == outFD { stdout.append(contentsOf: buffer.prefix(count)) }
                    else { stderr.append(contentsOf: buffer.prefix(count)) }
                    guard stdout.count + stderr.count <= limit else { throw NativeFileTree.fail("native command response exceeded the collection limit") }
                } else if errno != EAGAIN && errno != EINTR { throw NativeFileTree.fail("native command read failed") }
            }
        }
        while process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFileTree.fail("native command timed out") }; usleep(10_000)
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: stdout, error: stderr)
    }
}
