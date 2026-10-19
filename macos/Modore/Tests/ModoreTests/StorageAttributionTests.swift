import Darwin
import Foundation
import XCTest
@testable import Modore

final class StorageAttributionTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var nativeExecutable: URL {
        Bundle(for: StorageAttributionTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Modore")
    }
    private func request(_ root: URL, since: Double = 0, seen: Set<StorageAttribution.Identity> = []) -> StorageAttribution.Request {
        .init(label: "fixture", path: root.path, since: since, now: Date().timeIntervalSince1970 + 1, seen: seen)
    }

    func testBaselineUsesLatestPeakAndRejectsMalformedSamples() {
        let now = StorageAttribution.timestamp("2026-10-03T00:00:00Z")!
        let text = "2026-10-01T00:00:00Z\t200\n2026-10-02T00:00:00Z\t200\nbad\t500\n2026-10-04T00:00:00Z\t900\n2026-10-02T00:00:00Z\t9223372036854775807"
        let result = StorageAttribution.baseline(text: text, since: nil, now: now)
        XCTAssertEqual(result.0, now - 86400)
        XCTAssertEqual(result.1, 204800)
        XCTAssertNil(StorageAttribution.baseline(text: text, since: now - 3600, now: now).1)
    }

    func testNativeScannerMatchesPythonReferenceAndDoesNotFollowLinks() throws {
        let root = try temporary()
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("payload")
        try Data(repeating: 120, count: 8192).write(to: file)
        XCTAssertEqual(link(file.path, target.appendingPathComponent("hardlink").path), 0)
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("outside"), withDestinationURL: root)
        let input = request(target)
        let native = StorageAttribution.scan(input)
        XCTAssertTrue(native.row.complete)
        XCTAssertEqual(native.row.files, 1)
        let python = Process(), output = Pipe()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-I", "-B", "-c", "import importlib.util,json,sys; s=importlib.util.spec_from_file_location('reference',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(json.dumps(m.scan('fixture',sys.argv[2],0,float(sys.argv[3]))))",
            package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/storage_explain.py").path,
            target.path, String(input.now)]
        python.standardOutput = output
        try python.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        python.waitUntilExit()
        XCTAssertEqual(python.terminationStatus, 0)
        let reference = try JSONDecoder().decode(StorageAttribution.Row.self, from: data)
        XCTAssertEqual(native.row.allocatedBytes, reference.allocatedBytes)
        XCTAssertEqual(native.row.createdBytes, reference.createdBytes)
        XCTAssertEqual(native.row.modifiedBytes, reference.modifiedBytes)
        XCTAssertEqual(native.row.files, reference.files)
        XCTAssertEqual(native.row.errors, reference.errors)
    }

    func testModifiedOldFileIsNotGrowthAndMissingRootIsExplicit() throws {
        let root = try temporary(), file = root.appendingPathComponent("old")
        try Data(repeating: 1, count: 4096).write(to: file)
        let now = Date().timeIntervalSince1970
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now + 11)], ofItemAtPath: file.path)
        let row = StorageAttribution.scan(.init(label: "old", path: root.path, since: now + 10, now: now + 20, seen: [])).row
        XCTAssertEqual(row.createdBytes, 0)
        XCTAssertGreaterThan(row.modifiedBytes, 0)
        let missing = StorageAttribution.scan(request(root.appendingPathComponent("missing"))).row
        XCTAssertEqual(missing.status, "missing")
        XCTAssertTrue(missing.complete)
    }

    func testFailedAndStaleHistoryCannotProveGrowth() throws {
        let state = try temporary()
        let since = StorageAttribution.timestamp("2026-10-02T00:00:00Z")!
        try "path\t2026-10-01T00:00:00Z\t20\tok\told\t/tmp/old\npath\t2026-10-02T00:00:00Z\t0\ttimed_out\tbad\t/tmp/bad\npath\t2026-10-02T00:00:00Z\t40\tok\tgood\t/tmp/good\n".write(to: state.appendingPathComponent("storage-evidence-fixture.tsv"), atomically: true, encoding: .utf8)
        let measurements = StorageAttribution.pastMeasurements(state: state, since: since)
        XCTAssertEqual(measurements.count, 1)
        XCTAssertEqual(measurements[URL(fileURLWithPath: "/tmp/good").resolvingSymlinksInPath().path]?.bytes, 40960)
    }

    func testHistoryRejectsFIFOAndSymlinkWithoutBlocking() throws {
        let state = try temporary(), pipe = state.appendingPathComponent("storage-evidence-pipe.tsv")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let outside = state.appendingPathComponent("outside")
        let now = Date().timeIntervalSince1970
        try "path\t\(StorageAttribution.iso(now - 1))\t40\tok\tunsafe\t/tmp/unsafe\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("storage-evidence-link.tsv"), withDestinationURL: outside)
        XCTAssertTrue(StorageAttribution.pastMeasurements(state: state, since: now).isEmpty)
    }

    func testRealNativeWorkerPreservesHardlinkIdentityAcrossRoots() async throws {
        let root = try temporary(), a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 8192).write(to: a.appendingPathComponent("payload"))
        XCTAssertEqual(link(a.appendingPathComponent("payload").path, b.appendingPathComponent("link").path), 0)
        let binary = nativeExecutable
        let first = try await StorageAttributionService.measure(request(a), executable: binary)
        XCTAssertTrue(first.row.complete)
        XCTAssertEqual(first.row.files, 1)
        let second = try await StorageAttributionService.measure(request(b, seen: first.identities), executable: binary)
        XCTAssertTrue(second.row.complete)
        XCTAssertEqual(second.row.files, 0)
    }

    func testWorkerTimeoutIsIncompleteAndSubsequentWorkerRuns() async throws {
        let root = try temporary(), script = root.appendingPathComponent("stalled")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let failed = try await StorageAttributionService.measure(request(root), executable: script, timeout: 0.1)
        XCTAssertEqual(failed.row.status, "timeout")
        XCTAssertFalse(failed.row.complete)
        let next = try await StorageAttributionService.measure(request(root), executable: nativeExecutable)
        XCTAssertTrue(next.row.complete)
    }

    func testReportSeparatesMeasuredGrowthAndPersistsCompatibleHistory() async throws {
        let root = try temporary(), state = root.appendingPathComponent("state"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 8192).write(to: target.appendingPathComponent("payload"))
        let since = StorageAttribution.timestamp(StorageAttribution.iso(Date().timeIntervalSince1970 - 30))!
        try "path\t\(StorageAttribution.iso(since))\t1\tok\ttarget\t\(target.path)\n".write(to: state.appendingPathComponent("storage-evidence-test.tsv"), atomically: true, encoding: .utf8)
        let report = try await StorageAttributionService.run(home: root, state: state, since: since,
            targets: [("target", target.path)], worker: { StorageAttribution.scan($0) })
        XCTAssertEqual(report.rows[0].measuredDeltaBytes, report.rows[0].allocatedBytes - 1024)
        XCTAssertEqual(report.rows[0].recentDeltaBytes, report.rows[0].measuredDeltaBytes)
        XCTAssertNil(report.freeDropBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("storage-explanation-progress.json").path))
        let data = try Data(contentsOf: state.appendingPathComponent("storage-explanation.json"))
        XCTAssertEqual(try JSONDecoder().decode(StorageAttribution.Report.self, from: data).rows.count, 1)
        let history = StorageAttribution.pastMeasurements(state: state, since: Date().timeIntervalSince1970)
        XCTAssertEqual(history[target.path]?.bytes, report.rows[0].allocatedBytes)
    }

    func testCancellationDoesNotReplacePreviousReport() async throws {
        let state = try temporary(), url = state.appendingPathComponent("storage-explanation.json")
        try Data("previous".utf8).write(to: url)
        let task = Task {
            try await StorageAttributionService.run(home: state, state: state,
                targets: [("cancelled", state.path)], worker: { _ in throw CancellationError() })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error }
        XCTAssertEqual(try String(contentsOf: url), "previous")
    }
}
