import Darwin
import XCTest
@testable import MothballCore

final class ProcessRunnerTests: XCTestCase {
    func test_normalLeaderExitDoesNotLeakItsDetachedChild() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MothballProcessNormalExit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let childMarker = root.appending(path: "child-pid")
        let command = root.appending(path: "leave-child")
        try Data("""
        #!/bin/sh
        (
          trap '' TERM
          echo $$ > "$1"
          while :; do /bin/sleep 30; done
        ) &
        while [ ! -s "$1" ]; do /bin/sleep 0.01; done
        exit 0
        """.utf8).write(to: command)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: command.path
        )

        let started = Date()
        let result = try await ProcessRunner.run(
            executable: command,
            arguments: [childMarker.path],
            timeout: .seconds(10)
        )
        let observedChildProcessID = await waitForProcessID(in: childMarker)
        let childProcessID = try XCTUnwrap(observedChildProcessID)
        defer { _ = Darwin.kill(childProcessID, SIGKILL) }

        XCTAssertTrue(result.isSuccess)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let childIsGone = await waitUntilGone(childProcessID)
        XCTAssertTrue(
            childIsGone,
            "a helper that outlives a successful leader must still be killed with its process group"
        )
    }

    func test_parentCancellationEscalatesAndThrowsCancellationError() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MothballProcessCancellation-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appending(path: "leader-pid")
        let childMarker = root.appending(path: "child-pid")
        let command = root.appending(path: "ignore-term")
        try Data("""
        #!/bin/sh
        trap '' TERM
        echo $$ > "$1"
        (
          trap '' TERM
          echo $$ > "$2"
          while :; do /bin/sleep 30; done
        ) &
        wait
        """.utf8)
            .write(to: command)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: command.path
        )

        let task = Task {
            try await ProcessRunner.run(
                executable: command,
                arguments: [marker.path, childMarker.path],
                timeout: .seconds(60)
            )
        }
        guard let processID = await waitForProcessID(in: marker) else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("취소 회귀 테스트 프로세스가 시작되지 않았습니다.")
        }
        guard let childProcessID = await waitForProcessID(in: childMarker) else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("취소 회귀 테스트 자식 프로세스가 시작되지 않았습니다.")
        }
        defer { _ = Darwin.kill(processID, SIGKILL) }
        defer { _ = Darwin.kill(childProcessID, SIGKILL) }

        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("취소된 실행이 성공으로 반환됐습니다.")
        } catch is CancellationError {
            // Expected: cancellation must not be remapped to timeout/failure.
        } catch {
            XCTFail("CancellationError 대신 \(error)를 반환했습니다.")
        }

        let elapsed = Date().timeIntervalSince(cancelledAt)
        XCTAssertGreaterThan(elapsed, 4, "SIGTERM 무시 프로세스는 SIGKILL 유예까지 살아 있어야 합니다.")
        XCTAssertLessThan(elapsed, 8, "취소 강제 종료 상한을 넘겼습니다.")
        errno = 0
        XCTAssertEqual(Darwin.kill(processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        errno = 0
        XCTAssertEqual(Darwin.kill(childProcessID, 0), -1)
        XCTAssertEqual(errno, ESRCH, "자식 프로세스도 같은 process group에서 정리되어야 합니다.")
    }

    private func waitForProcessID(in marker: URL) async -> pid_t? {
        for _ in 0..<200 {
            if let text = try? String(contentsOf: marker, encoding: .utf8),
               let processID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return processID
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func waitUntilGone(_ processID: pid_t) async -> Bool {
        for _ in 0..<200 {
            errno = 0
            if Darwin.kill(processID, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
