import Foundation
import XCTest
@testable import Modore

private actor ScanPipelineReturnGate {
    enum Phase: Equatable, Sendable {
        case scanner
        case normalReport
        case shareReport
    }

    private let target: Phase
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var released = false

    init(_ target: Phase) {
        self.target = target
    }

    func pause(if phase: Phase) async {
        guard phase == target else { return }
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ScanPipelineProbe {
    enum ScannerOutcome: Equatable, Sendable {
        case success
        case inconsistentOutput
        case failure
    }

    private let scannerOutcome: ScannerOutcome
    private let failShareReport: Bool
    private let swapCanonicalAfterNormalReport: Bool
    private let returnGate: ScanPipelineReturnGate?
    private(set) var requests: [ScanPipelineProcessRequest] = []

    init(
        scannerOutcome: ScannerOutcome,
        failShareReport: Bool = false,
        swapCanonicalAfterNormalReport: Bool = false,
        returnGate: ScanPipelineReturnGate? = nil
    ) {
        self.scannerOutcome = scannerOutcome
        self.failShareReport = failShareReport
        self.swapCanonicalAfterNormalReport = swapCanonicalAfterNormalReport
        self.returnGate = returnGate
    }

    func run(
        _ request: ScanPipelineProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        requests.append(request)
        if let outputIndex = request.arguments.firstIndex(of: "--output"),
           let rawIndex = request.arguments.firstIndex(of: "--raw"),
           request.arguments.indices.contains(outputIndex + 1),
           request.arguments.indices.contains(rawIndex + 1) {
            guard scannerOutcome != .failure else { return 9 }
            do {
                let scanTimestamp = "2026-09-01 09:00:00"
                let rawTimestamp = scannerOutcome == .inconsistentOutput
                    ? "2026-09-01 09:00:01" : scanTimestamp
                try Self.writeJSON(
                    scannedAt: scanTimestamp,
                    to: Self.outputURL(
                        request.arguments[outputIndex + 1],
                        currentDirectory: request.currentDirectory
                    )
                )
                try Self.writeJSON(
                    scannedAt: rawTimestamp,
                    to: Self.outputURL(
                        request.arguments[rawIndex + 1],
                        currentDirectory: request.currentDirectory
                    )
                )
                onOutput("scanner complete")
                await returnGate?.pause(if: .scanner)
                return 0
            } catch {
                return 70
            }
        }

        guard let reportPath = request.environment["PCH_REPORT_OUTPUT"] else {
            return 64
        }
        guard let scanData = request.pinnedFiles["scan_result"],
              let scan = try? JSONSerialization.jsonObject(with: scanData) as? [String: Any],
              scan["scannedAt"] as? String == "2026-09-01 09:00:00",
              request.arguments.contains("@pch-pinned:scan_result") else {
            return 66
        }
        if failShareReport, request.environment["PCH_REDACT"] == "true" {
            return 8
        }
        do {
            try Data("<html>report</html>".utf8).write(
                to: Self.outputURL(
                    reportPath,
                    currentDirectory: request.currentDirectory
                ),
                options: .atomic
            )
            if swapCanonicalAfterNormalReport,
               request.environment["PCH_REDACT"] != "true" {
                guard let outputRoot = request.environment["PCH_PROJECT_DIR"],
                      Self.replaceCanonical(in: URL(fileURLWithPath: outputRoot)) else {
                    return 71
                }
            }
            await returnGate?.pause(
                if: request.environment["PCH_REDACT"] == "true"
                    ? .shareReport : .normalReport
            )
            return 0
        } catch {
            return 70
        }
    }

    private static func writeJSON(scannedAt: String, to url: URL) throws {
        let payload: [String: Any] = [
            "schemaVersion": "1.0",
            "scannedAt": scannedAt,
            "sections": [:],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
    }

    private static func replaceCanonical(in outputRoot: URL) -> Bool {
        guard let parentIdentity = FilesystemIdentity.directory(at: outputRoot),
              let staged = try? ScanPublication.prepare(
                in: outputRoot,
                expectedParentIdentity: parentIdentity
              ) else {
            return false
        }
        defer { ScanPublication.discard(staged) }
        do {
            try writeJSON(scannedAt: "2026-09-01 10:00:00", to: staged.scanResultURL)
            try writeJSON(scannedAt: "2026-09-01 10:00:00", to: staged.rawFactsURL)
        } catch {
            return false
        }
        return ScanPublication.publish(
            staged,
            in: outputRoot,
            expectedParentIdentity: parentIdentity
        )
    }

    private static func outputURL(_ path: String, currentDirectory: URL) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : currentDirectory.appendingPathComponent(path)
    }
}

final class ScanPipelineTests: XCTestCase {
    private func executionContext(
        sealed: Bool = false
    ) throws -> (container: URL, context: RuntimeExecutionContext) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("modore-scan-pipeline-\(UUID().uuidString)", isDirectory: true)
        let runtime = container.appendingPathComponent("runtime", isDirectory: true)
        let output = container.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let configuration = container.appendingPathComponent("config.json")
        try Data("{}\n".utf8).write(to: configuration, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configuration.path
        )
        let context = RuntimeExecutionContext(
            runtimeRoot: runtime,
            outputRoot: output,
            configurationURL: configuration,
            usesBundledRuntime: sealed,
            runtimeRootIdentity: try XCTUnwrap(FilesystemIdentity.directory(at: runtime)),
            outputRootIdentity: try XCTUnwrap(FilesystemIdentity.directory(at: output)),
            signedBundleURL: nil,
            sealedRuntimeFiles: sealed ? sealedRuntimeFiles() : nil
        )
        return (container, context)
    }

    private func sealedRuntimeFiles() -> [String: Data] {
        let paths = [
            "scripts/scanner.sh",
            "scripts/report.jxa.js",
            "scripts/idle_cpu.sh",
            "scripts/scanner_helper.jxa.js",
            "scripts/modules/support_dir.sh",
            "scripts/modules/macos/cpu.sh",
            "scripts/modules/macos/network.sh",
            "scripts/modules/macos/autoruns.sh",
            "scripts/modules/macos/security.sh",
            "scripts/modules/macos/storage.sh",
            "scripts/modules/macos/idle_cpu.sh",
            "scripts/modules/macos/privacy.sh",
            "scripts/modules/macos/devtool_updates.sh",
            "data/whitelist.json",
            "rules/autoruns.json",
            "rules/defender.json",
            "rules/installs.json",
            "rules/network.json",
            "rules/process.json",
        ]
        return Dictionary(uniqueKeysWithValues: paths.map {
            ($0, Data("sealed \($0)".utf8))
        })
    }

    private func dependencies(
        context: RuntimeExecutionContext,
        probe: ScanPipelineProbe
    ) -> ScanPipelineDependencies {
        ScanPipelineDependencies(
            prepareExecution: { _ in context },
            runProcess: { request, onOutput in
                await probe.run(request, onOutput: onOutput)
            }
        )
    }

    func testSuccessfulRunPublishesConsistentSnapshotAndBothReports() async throws {
        let fixture = try executionContext()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let probe = ScanPipelineProbe(scannerOutcome: .success)
        try Data("{\"scannedAt\":\"stale\"}\n".utf8).write(
            to: fixture.context.outputRoot.appendingPathComponent("scan_result.json"),
            options: .atomic
        )

        let result = await ScanPipeline.run(
            projectRoot: fixture.context.outputRoot,
            dependencies: dependencies(context: fixture.context, probe: probe),
            onOutput: { _ in }
        )

        XCTAssertEqual(result, ScanRunResult(
            scan: .succeeded,
            normalReport: .succeeded,
            shareReport: .succeeded
        ))
        let canonical = try XCTUnwrap(ScanPublication.canonicalDirectory(
            in: fixture.context.outputRoot
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: canonical.url.appendingPathComponent("scan_result.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: canonical.url.appendingPathComponent("raw_facts.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.context.outputRoot.appendingPathComponent("검사결과.html").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.context.outputRoot.appendingPathComponent("검사결과_공유용.html").path
        ))
        for reportName in ["검사결과.html", "검사결과_공유용.html"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fixture.context.outputRoot.appendingPathComponent(reportName).path
            )
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }

        let requests = await probe.requests
        XCTAssertEqual(requests.count, 3)
        let reportRequests = requests.filter { $0.environment["PCH_REPORT_OUTPUT"] != nil }
        XCTAssertEqual(reportRequests.count, 2)
        let normalRequest = try XCTUnwrap(reportRequests.first)
        let shareRequest = try XCTUnwrap(reportRequests.last)
        XCTAssertNil(normalRequest.environment["PCH_REDACT"])
        XCTAssertEqual(shareRequest.environment["PCH_REDACT"], "true")
        XCTAssertNil(normalRequest.environment["PCH_SCAN"])
        XCTAssertNotNil(normalRequest.pinnedFiles["scan_result"])
        XCTAssertTrue(normalRequest.arguments.contains("@pch-pinned:scan_result"))
    }

    func testScannerFailureDoesNotRunReportsOrPublishSnapshot() async throws {
        let fixture = try executionContext()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let probe = ScanPipelineProbe(scannerOutcome: .failure)

        let result = await ScanPipeline.run(
            projectRoot: fixture.context.outputRoot,
            dependencies: dependencies(context: fixture.context, probe: probe),
            onOutput: { _ in }
        )

        XCTAssertEqual(result, .scanFailed)
        XCTAssertNil(ScanPublication.canonicalDirectory(in: fixture.context.outputRoot))
        let requestCount = await probe.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testReportFailureDoesNotDiscardPublishedScanOrSuccessfulReport() async throws {
        let fixture = try executionContext()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let probe = ScanPipelineProbe(scannerOutcome: .success, failShareReport: true)

        let result = await ScanPipeline.run(
            projectRoot: fixture.context.outputRoot,
            dependencies: dependencies(context: fixture.context, probe: probe),
            onOutput: { _ in }
        )

        XCTAssertEqual(result, ScanRunResult(
            scan: .succeeded,
            normalReport: .succeeded,
            shareReport: .failed
        ))
        XCTAssertNotNil(ScanPublication.canonicalDirectory(in: fixture.context.outputRoot))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.context.outputRoot.appendingPathComponent("검사결과.html").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.context.outputRoot.appendingPathComponent("검사결과_공유용.html").path
        ))
        let requestCount = await probe.requests.count
        XCTAssertEqual(requestCount, 3)
    }

    func testCanonicalSwapPreventsOlderPipelineFromPublishingReports() async throws {
        let fixture = try executionContext()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let probe = ScanPipelineProbe(
            scannerOutcome: .success,
            swapCanonicalAfterNormalReport: true
        )

        let result = await ScanPipeline.run(
            projectRoot: fixture.context.outputRoot,
            dependencies: dependencies(context: fixture.context, probe: probe),
            onOutput: { _ in }
        )

        XCTAssertEqual(result, ScanRunResult(
            scan: .succeeded,
            normalReport: .failed,
            shareReport: .failed
        ))
        let requests = await probe.requests
        let reportRequests = requests.filter { $0.environment["PCH_REPORT_OUTPUT"] != nil }
        XCTAssertEqual(reportRequests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.context.outputRoot.appendingPathComponent("검사결과.html").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.context.outputRoot.appendingPathComponent("검사결과_공유용.html").path
        ))

        let canonical = try XCTUnwrap(ScanPublication.canonicalDirectory(
            in: fixture.context.outputRoot
        ))
        let current = try Data(contentsOf: canonical.url.appendingPathComponent("scan_result.json"))
        let currentJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: current) as? [String: Any]
        )
        XCTAssertEqual(currentJSON["scannedAt"] as? String, "2026-09-01 10:00:00")
    }

    func testSealedRuntimePinsScannerModulesAndReportInputs() async throws {
        let fixture = try executionContext(sealed: true)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let probe = ScanPipelineProbe(scannerOutcome: .success)

        let result = await ScanPipeline.run(
            projectRoot: fixture.context.outputRoot,
            dependencies: dependencies(context: fixture.context, probe: probe),
            onOutput: { _ in }
        )

        XCTAssertTrue(result.scanSucceeded)
        XCTAssertTrue(result.reportsSucceeded)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 3)
        let scanner = try XCTUnwrap(requests.first)
        XCTAssertEqual(scanner.arguments, [
            "@pch-pinned:scanner",
            "--output", "scan_result.json",
            "--raw", "raw_facts.json",
        ])
        XCTAssertNotNil(scanner.pinnedFiles["scanner"])
        XCTAssertNotNil(scanner.pinnedFiles["support_dir"])
        XCTAssertEqual(scanner.environment["PCH_PINNED_CPU_MODULE"], "@pch-pinned:cpu")

        let reports = requests.dropFirst()
        XCTAssertTrue(reports.allSatisfy { $0.pinnedFiles["report"] != nil })
        XCTAssertTrue(reports.allSatisfy { $0.pinnedFiles["scan_result"] != nil })
        XCTAssertTrue(reports.allSatisfy {
            $0.arguments.contains("@pch-pinned:scan_result")
        })
    }

    func testMismatchedScannerOutputsAreDiscardedBeforePublication() async throws {
        let fixture = try executionContext()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let probe = ScanPipelineProbe(scannerOutcome: .inconsistentOutput)

        let result = await ScanPipeline.run(
            projectRoot: fixture.context.outputRoot,
            dependencies: dependencies(context: fixture.context, probe: probe),
            onOutput: { _ in }
        )

        XCTAssertEqual(result, .scanFailed)
        XCTAssertNil(ScanPublication.canonicalDirectory(in: fixture.context.outputRoot))
        let requestCount = await probe.requests.count
        XCTAssertEqual(requestCount, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.context.outputRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".modore-scan-run-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testCancellationAfterScannerSuccessDiscardsStagingAndSkipsPublication() async throws {
        let fixture = try executionContext()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let gate = ScanPipelineReturnGate(.scanner)
        let probe = ScanPipelineProbe(
            scannerOutcome: .success,
            returnGate: gate
        )
        let dependencies = dependencies(context: fixture.context, probe: probe)
        let task = Task {
            await ScanPipeline.run(
                projectRoot: fixture.context.outputRoot,
                dependencies: dependencies,
                onOutput: { _ in }
            )
        }

        for _ in 0..<400 {
            if await gate.entered { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let scannerDidEnter = await gate.entered
        XCTAssertTrue(scannerDidEnter)
        task.cancel()
        await gate.release()
        let result = await task.value

        XCTAssertEqual(result, .scanFailed)
        XCTAssertNil(ScanPublication.canonicalDirectory(in: fixture.context.outputRoot))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.context.outputRoot.appendingPathComponent("검사결과.html").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.context.outputRoot.appendingPathComponent("검사결과_공유용.html").path
        ))
        let requestCount = await probe.requests.count
        XCTAssertEqual(requestCount, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.context.outputRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".modore-scan-run-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testCancellationAfterNormalReportProcessPreservesCanonicalReport() async throws {
        let fixture = try executionContext()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let normalReport = fixture.context.outputRoot.appendingPathComponent("검사결과.html")
        let previousReport = Data("previous report".utf8)
        try previousReport.write(to: normalReport, options: .atomic)
        let gate = ScanPipelineReturnGate(.normalReport)
        let probe = ScanPipelineProbe(
            scannerOutcome: .success,
            returnGate: gate
        )
        let dependencies = dependencies(context: fixture.context, probe: probe)
        let task = Task {
            await ScanPipeline.run(
                projectRoot: fixture.context.outputRoot,
                dependencies: dependencies,
                onOutput: { _ in }
            )
        }

        for _ in 0..<400 {
            if await gate.entered { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let reportDidEnter = await gate.entered
        XCTAssertTrue(reportDidEnter)
        task.cancel()
        await gate.release()
        let result = await task.value

        XCTAssertEqual(result, ScanRunResult(
            scan: .succeeded,
            normalReport: .notAttempted,
            shareReport: .notAttempted
        ))
        XCTAssertNotNil(ScanPublication.canonicalDirectory(in: fixture.context.outputRoot))
        XCTAssertEqual(try Data(contentsOf: normalReport), previousReport)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.context.outputRoot.appendingPathComponent("검사결과_공유용.html").path
        ))
        let requestCount = await probe.requests.count
        XCTAssertEqual(requestCount, 2)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.context.outputRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".modore-scan-run-") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
