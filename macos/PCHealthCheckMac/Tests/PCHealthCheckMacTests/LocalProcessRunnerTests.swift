import Darwin
import Foundation
import XCTest
@testable import PCHealthCheckMac

final class LocalProcessRunnerTests: XCTestCase {
    func testCaptureTimesOutAndReturnsBoundedStatus() async {
        let started = Date()
        let result = await LocalProcessRunner.capture(
            executable: "/bin/sleep",
            arguments: ["5"],
            currentDirectory: FileManager.default.temporaryDirectory,
            timeout: 0.1
        )

        XCTAssertEqual(result.status, LocalProcessRunner.timeoutStatus)
        XCTAssertEqual(result.endState, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testRootExitKillsSIGTERMIgnoringChildHoldingTheOutputPipe() async {
        let started = Date()
        let result = await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [
                "-c",
                "trap '' TERM; /bin/sleep 30 & child=$!; printf 'child=%s\\n' \"$child\"; exit 0",
            ],
            currentDirectory: FileManager.default.temporaryDirectory,
            timeout: 5
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.endState, .exited)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.8)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        guard let childPID = processID(named: "child", in: result.output) else {
            XCTFail("자손 PID가 출력되지 않았습니다: \(result.output)")
            return
        }
        await assertProcessDisappears(childPID)
    }

    func testTimeoutKillsSIGTERMIgnoringRootAndChildHoldingTheOutputPipe() async {
        let started = Date()
        let result = await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [
                "-c",
                "trap '' TERM; /bin/sleep 30 & child=$!; printf 'root=%s child=%s\\n' \"$$\" \"$child\"; wait \"$child\"",
            ],
            currentDirectory: FileManager.default.temporaryDirectory,
            timeout: 0.25
        )

        XCTAssertEqual(result.status, LocalProcessRunner.timeoutStatus)
        XCTAssertEqual(result.endState, .timedOut)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        guard let rootPID = processID(named: "root", in: result.output),
              let childPID = processID(named: "child", in: result.output) else {
            XCTFail("루트/자손 PID가 출력되지 않았습니다: \(result.output)")
            return
        }
        await assertProcessDisappears(rootPID)
        await assertProcessDisappears(childPID)
    }

    func testTaskCancellationKillsSIGTERMIgnoringRootAndChild() async {
        let readySignal = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-process-runner-\(UUID().uuidString).ready")
        defer { try? FileManager.default.removeItem(at: readySignal) }
        let task = Task {
            await LocalProcessRunner.capture(
                executable: "/bin/bash",
                arguments: [
                    "-c",
                    "trap '' TERM; /bin/sleep 30 & child=$!; printf 'root=%s child=%s\\n' \"$$\" \"$child\"; printf ready > \"$1\"; wait \"$child\"",
                    "runner-cancellation-test",
                    readySignal.path,
                ],
                currentDirectory: FileManager.default.temporaryDirectory,
                timeout: nil
            )
        }
        guard await waitForFile(at: readySignal) else {
            task.cancel()
            _ = await task.value
            XCTFail("취소 회귀 테스트 프로세스가 준비되지 않았습니다.")
            return
        }
        let cancelledAt = Date()
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.endState, .cancelled)
        XCTAssertGreaterThan(Date().timeIntervalSince(cancelledAt), 0.8)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 3)
        guard let rootPID = processID(named: "root", in: result.output),
              let childPID = processID(named: "child", in: result.output) else {
            XCTFail("루트/자손 PID가 출력되지 않았습니다: \(result.output)")
            return
        }
        await assertProcessDisappears(rootPID)
        await assertProcessDisappears(childPID)
    }

    func testOutputLimitSignalsOnceThenEscalates() async throws {
        let signalRecord = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-process-runner-\(UUID().uuidString).signals")
        defer { try? FileManager.default.removeItem(at: signalRecord) }
        let started = Date()
        let result = await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [
                "-c",
                "trap 'printf x >> \"$1\"' TERM; printf '%4096s' ''; while :; do /bin/sleep 0.05; done",
                "runner-output-limit-test",
                signalRecord.path,
            ],
            currentDirectory: FileManager.default.temporaryDirectory,
            timeout: 5,
            maxOutputBytes: 1_024
        )

        XCTAssertEqual(result.status, LocalProcessRunner.outputLimitStatus)
        XCTAssertEqual(result.endState, .outputLimit)
        XCTAssertTrue(result.outputTruncated)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 1_200)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.8)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(try String(contentsOf: signalRecord, encoding: .utf8), "x")
    }

    func testStreamPreservesSplitUTF8AndLineOrder() async {
        let collector = LockedLineCollector()
        let status = await LocalProcessRunner.stream(
            executable: "/bin/bash",
            arguments: ["-c", "printf '\\355'; /bin/sleep 0.05; printf '\\225\\234\\nsecond\\n'"],
            currentDirectory: FileManager.default.temporaryDirectory,
            timeout: 5
        ) { line in
            collector.append(line)
        }

        XCTAssertEqual(status, 0)
        XCTAssertEqual(collector.snapshot(), ["한", "second"])
    }

    private func processID(named name: String, in output: String) -> pid_t? {
        let prefix = "\(name)="
        guard let field = output.split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return pid_t(field.dropFirst(prefix.count))
    }

    private func assertProcessDisappears(
        _ processID: pid_t,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<60 {
            errno = 0
            if Darwin.kill(processID, 0) == -1, errno == ESRCH {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        errno = 0
        let stillExists = Darwin.kill(processID, 0) == 0 || errno == EPERM
        if stillExists {
            _ = Darwin.kill(processID, SIGKILL)
        }
        XCTFail("프로세스 \(processID)가 제한 시간 안에 종료되지 않았습니다.", file: file, line: line)
    }

    private func waitForFile(at url: URL) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}

private final class LockedLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
