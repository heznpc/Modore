import XCTest
@testable import MothballCore

final class RepoScannerTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MothballScanner-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    func test_scanReportSurfacesInspectionFailures() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "git required at /usr/bin"
        )
        let brokenRepo = scratch.appending(path: "broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: brokenRepo, withIntermediateDirectories: true)
        try Data("not a real gitdir\n".utf8).write(to: brokenRepo.appending(path: ".git"))

        let report = await RepoScanner().scanReport(roots: [scratch])

        XCTAssertTrue(report.repos.isEmpty)
        let failure = try XCTUnwrap(report.failures.first)
        XCTAssertEqual(failure.path.standardizedFileURL, brokenRepo.standardizedFileURL)
        XCTAssertFalse(failure.reason.isEmpty)
    }

    func test_knownRepositoryInspectionNeverFallsBackToRecursiveDiscovery() async throws {
        let vanishedRoot = scratch.appending(path: "vanished-root", directoryHint: .isDirectory)
        let nestedRepo = vanishedRoot.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: nestedRepo.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let report = await RepoScanner().inspectKnownRepositories([vanishedRoot])

        XCTAssertTrue(report.repos.isEmpty)
        XCTAssertEqual(report.failures.map(\.path), [vanishedRoot])
    }

    func test_cancelledScanStopsAdmittingRepositoriesAndReturnsPromptly() async throws {
        let slowGit = scratch.appending(path: "slow-git")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: slowGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: slowGit.path
        )
        for index in 0..<12 {
            let repo = scratch.appending(path: "repo-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: repo.appending(path: ".git", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        let started = LockedCounter()
        let scanRoot = try XCTUnwrap(scratch)
        let scanner = RepoScanner(
            inspector: GitInspector(
                gitExecutable: slowGit,
                perCommandTimeout: .seconds(60)
            ),
            maxConcurrentInspections: 2,
            inspectionStarted: { _ in started.increment() }
        )
        let task = Task { await scanner.scanReport(roots: [scanRoot]) }
        XCTAssertTrue(started.wait(untilAtLeast: 2, timeout: 2))

        let cancelledAt = Date()
        task.cancel()
        _ = await task.value

        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 3)
        XCTAssertEqual(started.value, 2, "취소 뒤 새 저장소 검사를 시작하면 안 됩니다.")
    }

    func test_sizeMeasurementRejectsAnIncompleteEntryLimitedResult() async throws {
        let files = scratch.appending(path: "files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for index in 0..<5 {
            try Data([UInt8(index % 255)]).write(to: files.appending(path: "\(index).txt"))
        }

        do {
            _ = try await SizeAndActivity.measure(at: files, maxEntries: 2)
            XCTFail("파일 수 상한을 넘긴 측정이 성공으로 보이면 안 됩니다.")
        } catch let error as SizeAndActivity.Error {
            guard case .entryLimitExceeded(2) = error else {
                return XCTFail("예상하지 못한 측정 오류: \(error)")
            }
        }
    }

    func test_sizeMeasurementCancellationKillsItsSubprocessPromptly() async throws {
        let marker = scratch.appending(path: "measurement-ready")
        let slowShell = scratch.appending(path: "slow-shell")
        try Data("#!/bin/sh\n/usr/bin/touch \"\(marker.path)\"\nexec /bin/sleep 30\n".utf8)
            .write(to: slowShell)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: slowShell.path
        )

        let scanRoot = try XCTUnwrap(scratch)
        let task = Task {
            try await SizeAndActivity.measure(
                at: scanRoot,
                timeout: .seconds(20),
                shellExecutable: slowShell
            )
        }
        let becameReady = await waitForFile(marker)
        XCTAssertTrue(becameReady)

        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("취소한 측정이 성공하면 안 됩니다.")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
    }

    func test_scanBudgetCancelsInFlightWorkAndNamesEveryUninspectedRepo() async throws {
        let slowGit = scratch.appending(path: "budget-git")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: slowGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: slowGit.path
        )
        var roots: [URL] = []
        for index in 0..<4 {
            let repo = scratch.appending(path: "budget-repo-\(index)")
            try FileManager.default.createDirectory(
                at: repo.appending(path: ".git"),
                withIntermediateDirectories: true
            )
            roots.append(repo)
        }
        let scanner = RepoScanner(
            inspector: GitInspector(
                gitExecutable: slowGit,
                perCommandTimeout: .seconds(20)
            ),
            maxConcurrentInspections: 2,
            totalScanBudget: .milliseconds(150)
        )

        let started = Date()
        let report = await scanner.scanReport(roots: roots)

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(report.repos.isEmpty)
        XCTAssertEqual(Set(report.failures.map(\.path)), Set(roots))
        XCTAssertTrue(report.failures.allSatisfy { $0.reason.contains("시간 상한") })
    }

    private func waitForFile(_ url: URL) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0

    var value: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }

    func increment() {
        condition.lock()
        count += 1
        condition.broadcast()
        condition.unlock()
    }

    func wait(untilAtLeast target: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while count < target {
            guard condition.wait(until: deadline) else { return count >= target }
        }
        return true
    }
}
