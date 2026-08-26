import XCTest
@testable import Modore

final class ModoreTests: XCTestCase {
    func testCompletedScanRemainsSuccessfulWhenAReportFails() {
        let result = ScanRunResult(
            scan: .succeeded,
            normalReport: .succeeded,
            shareReport: .failed
        )
        let reportState = ReportState(
            runResult: result,
            attemptedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertTrue(result.scanSucceeded)
        XCTAssertFalse(result.reportsSucceeded)
        XCTAssertEqual(reportState.normal, .generated)
        XCTAssertEqual(reportState.share, .failed)
        XCTAssertEqual(
            reportState.failureText,
            "정밀 검사는 완료됐지만 공유용 리포트를 생성하지 못했습니다."
        )
    }

    func testUnattemptedReportsRemainUnknownAfterScannerFailure() {
        let reportState = ReportState(
            runResult: .scanFailed,
            attemptedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(reportState.normal, .unknown)
        XCTAssertEqual(reportState.share, .unknown)
        XCTAssertNil(reportState.failureText)
    }

    func testAutomaticScanWaitsForRestoreAndDoesNotOverlapBusyWork() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertFalse(ScanModel.shouldRunAutomaticScan(
            initialResultsLoaded: false,
            isBusy: false,
            lastStorageScanAt: nil,
            hasNewerStorageHistory: false,
            lastScanAttemptAt: nil,
            now: now
        ))
        XCTAssertFalse(ScanModel.shouldRunAutomaticScan(
            initialResultsLoaded: true,
            isBusy: true,
            lastStorageScanAt: nil,
            hasNewerStorageHistory: false,
            lastScanAttemptAt: nil,
            now: now
        ))
    }

    func testAutomaticScanRefreshesMissingStaleOrSupersededResults() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = now.addingTimeInterval(-ScanModel.storageSnapshotFreshnessInterval + 1)
        let stale = now.addingTimeInterval(-ScanModel.storageSnapshotFreshnessInterval)

        XCTAssertTrue(ScanModel.shouldRunAutomaticScan(
            initialResultsLoaded: true,
            isBusy: false,
            lastStorageScanAt: nil,
            hasNewerStorageHistory: false,
            lastScanAttemptAt: nil,
            now: now
        ))
        XCTAssertFalse(ScanModel.shouldRunAutomaticScan(
            initialResultsLoaded: true,
            isBusy: false,
            lastStorageScanAt: fresh,
            hasNewerStorageHistory: false,
            lastScanAttemptAt: nil,
            now: now
        ))
        XCTAssertTrue(ScanModel.shouldRunAutomaticScan(
            initialResultsLoaded: true,
            isBusy: false,
            lastStorageScanAt: stale,
            hasNewerStorageHistory: false,
            lastScanAttemptAt: nil,
            now: now
        ))
        XCTAssertTrue(ScanModel.shouldRunAutomaticScan(
            initialResultsLoaded: true,
            isBusy: false,
            lastStorageScanAt: fresh,
            hasNewerStorageHistory: true,
            lastScanAttemptAt: nil,
            now: now
        ))
    }

    func testAutomaticScanThrottlesRecentFailedAttempt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertFalse(ScanModel.shouldRunAutomaticScan(
            initialResultsLoaded: true,
            isBusy: false,
            lastStorageScanAt: nil,
            hasNewerStorageHistory: false,
            lastScanAttemptAt: now.addingTimeInterval(
                -ScanModel.automaticScanRetryInterval + 1
            ),
            now: now
        ))
        XCTAssertTrue(ScanModel.shouldRunAutomaticScan(
            initialResultsLoaded: true,
            isBusy: false,
            lastStorageScanAt: nil,
            hasNewerStorageHistory: false,
            lastScanAttemptAt: now.addingTimeInterval(
                -ScanModel.automaticScanRetryInterval
            ),
            now: now
        ))
    }

    func testScanEnvironmentRequiresExplicitVTConsentAndValidAndroidPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-scan-environment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = root.appendingPathComponent("config.json")
        let android = root.appendingPathComponent("android-sdk")
        let androidLink = root.appendingPathComponent("android-link")
        try FileManager.default.createDirectory(at: android, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: androidLink, withDestinationURL: android)
        try "{\"virustotal\":{\"enabled\":false,\"apiKey\":\"\"}}".write(
            to: configuration,
            atomically: true,
            encoding: .utf8
        )

        var environment = ScanPipeline.scanEnvironment(
            configurationURL: configuration,
            processEnvironment: [
                "VT_API_KEY": "secret",
                "ANDROID_HOME": android.path,
                "ANDROID_SDK_ROOT": androidLink.path,
                "PCH_TEST_MODE": "1",
            ]
        )
        XCTAssertNil(environment["VT_API_KEY"])
        XCTAssertEqual(environment["ANDROID_HOME"], android.path)
        XCTAssertNil(environment["ANDROID_SDK_ROOT"])
        XCTAssertNil(environment["PCH_TEST_MODE"])

        try "{\"virustotal\":{\"enabled\":true,\"apiKey\":\"\"}}".write(
            to: configuration,
            atomically: true,
            encoding: .utf8
        )
        environment = ScanPipeline.scanEnvironment(
            configurationURL: configuration,
            processEnvironment: ["VT_API_KEY": " secret "]
        )
        XCTAssertEqual(environment["VT_API_KEY"], "secret")
    }

    func testStorageTotalsExcludeNestedAndDeferredMeasurements() throws {
        let snapshot = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(),
            "cleanupCandidates": [
                storageJSON(label: "Root cache", sizeGB: 10, path: "/cache", cleanupID: "npm_cache"),
                storageJSON(label: "Nested cache", sizeGB: 4, path: "/cache/nested", cleanupID: "pnpm_store"),
                storageJSON(
                    label: "Deferred",
                    sizeGB: 99,
                    path: "/slow",
                    measureStatus: "timed_out",
                    cleanupID: "gradle_cache"
                ),
            ],
            "developerToolchains": [
                storageJSON(kind: "android_sdk", label: "Android SDK", sizeGB: 11, path: "/sdk"),
                storageJSON(kind: "android_tool", label: "Command-line tools", sizeGB: 3, path: "/sdk/cmdline-tools"),
                storageJSON(kind: "simulator_devices", label: "Simulator devices", sizeGB: 6, path: "/simulators"),
            ],
        ]))

        XCTAssertEqual(snapshot.reclaimableGB, 10, accuracy: 0.001)
        XCTAssertEqual(snapshot.developerGB, 11, accuracy: 0.001)
        XCTAssertEqual(snapshot.simulatorGB, 6, accuracy: 0.001)
        XCTAssertEqual(snapshot.reclaimableText, "10.0GB+")
    }

    func testScanContentParsesOneCoherentSnapshot() throws {
        let content = ScanContent(root: [
            "summary": ["status": "warning", "message": "확인 필요", "warningCount": 1],
            "findings": [["level": "warning", "title": "Unknown item", "detail": "Review it"]],
            "sections": [
                "storage": ["volume": volume()],
                "cpu": [["risk": "safe", "name": "kernel_task", "pid_": 1, "cpu": 0.1]],
                "network": [[
                    "risk": "unknown",
                    "process": "Example",
                    "pid_": 7,
                    "remoteAddress": "203.0.113.1",
                    "remotePort": 443,
                    "path": "/Applications/Example.app/Contents/MacOS/Example",
                ]],
                "listeningPorts": [[
                    "risk": "unknown",
                    "name": "Local service",
                    "process": "Example",
                    "pid_": 7,
                    "port": 8080,
                    "path": "/Applications/Example.app/Contents/MacOS/Example",
                ]],
            ],
        ])

        XCTAssertEqual(content.summary?.warningCount, 1)
        XCTAssertEqual(content.findings.count, 1)
        XCTAssertEqual(content.cpuRows.count, 1)
        XCTAssertEqual(content.networkRows.first?.pid, 7)
        XCTAssertEqual(content.networkRows.first?.path, "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertEqual(content.listeningPortRows.first?.port, 8080)
        XCTAssertNotNil(content.storage)
    }

    func testCollectionCoverageDistinguishesOptionalGapsFromFullCoverage() throws {
        let coverage = try XCTUnwrap(CollectionCoverage(json: [
            "complete": true,
            "completedCount": 2,
            "sourceCount": 3,
            "completedRequiredCount": 2,
            "requiredCount": 2,
            "sources": [
                ["id": "cpu", "label": "CPU", "status": "ok", "required": true],
                ["id": "network", "label": "Network", "status": "ok", "required": true],
                ["id": "optional", "label": "Optional", "status": "unavailable", "required": false],
            ],
        ]))

        XCTAssertTrue(coverage.complete)
        XCTAssertFalse(coverage.allSourcesComplete)
        XCTAssertEqual(coverage.requiredIssues.count, 0)
        XCTAssertEqual(coverage.optionalIssues.map(\.id), ["optional"])
    }

    @MainActor
    func testScanLogStoreBoundsAndClearsOutput() {
        let store = ScanLogStore()
        store.append(String(repeating: "x", count: 210_000))

        XCTAssertEqual(store.text.count, 200_000)
        XCTAssertFalse(store.isEmpty)

        store.clear()
        XCTAssertTrue(store.isEmpty)
    }

    func testCapturedProcessDrainsLargeOutputWhileRunning() async {
        let result = await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 1048576"],
            currentDirectory: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 1_048_576)
    }

    func testTimedOutHistoryRowsAreNotReportedAsDeleted() throws {
        let previous = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(freeGB: 30),
            "cleanupCandidates": [
                storageJSON(label: "Growing", sizeGB: 2, path: "/growing", cleanupID: "growing"),
                storageJSON(
                    label: "Timed scan row",
                    sizeGB: 5,
                    path: "/missing",
                    measureStatus: "timed_out",
                    cleanupID: "missing"
                ),
            ],
        ]))
        let current = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(freeGB: 29),
            "cleanupCandidates": [
                storageJSON(label: "Growing", sizeGB: 3, path: "/growing", cleanupID: "growing"),
            ],
        ]))
        let entries = [
            StorageHistoryEntry(sourceID: "before", capturedAt: Date(timeIntervalSince1970: 1), storage: previous),
            StorageHistoryEntry(sourceID: "after", capturedAt: Date(timeIntervalSince1970: 2), storage: current),
        ]
        let summary = try XCTUnwrap(StorageChangeSummary(entries: entries))

        XCTAssertEqual(summary.itemChanges.count, 1)
        XCTAssertEqual(summary.itemChanges.first?.label, "Growing")
        XCTAssertEqual(summary.itemChanges.first?.deltaGB ?? 0, 1, accuracy: 0.001)
    }

    func testDisplayedSnapshotChangeDoesNotUseNewerHistoryEntry() throws {
        let first = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(freeGB: 30),
            "cleanupCandidates": [
                storageJSON(label: "Cache", sizeGB: 1, path: "/cache", cleanupID: "cache"),
            ],
        ]))
        let displayed = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(freeGB: 29),
            "cleanupCandidates": [
                storageJSON(label: "Cache", sizeGB: 2, path: "/cache", cleanupID: "cache"),
            ],
        ]))
        let newer = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(freeGB: 20),
            "cleanupCandidates": [
                storageJSON(label: "Cache", sizeGB: 9, path: "/cache", cleanupID: "cache"),
            ],
        ]))
        let entries = [
            StorageHistoryEntry(sourceID: "first", capturedAt: Date(timeIntervalSince1970: 1), storage: first),
            StorageHistoryEntry(sourceID: "displayed", capturedAt: Date(timeIntervalSince1970: 2), storage: displayed),
            StorageHistoryEntry(sourceID: "newer", capturedAt: Date(timeIntervalSince1970: 3), storage: newer),
        ]

        let summary = try XCTUnwrap(
            StorageHistoryStore.changeSummary(endingAt: "displayed", in: entries)
        )

        XCTAssertEqual(summary.current.sourceID, "displayed")
        XCTAssertEqual(summary.freeDeltaGB, -1, accuracy: 0.001)
        XCTAssertEqual(summary.largestChanges.first?.afterGB ?? 0, 2, accuracy: 0.001)
    }

    func testProtectedHistoryCannotBecomeCleanupCandidateWithoutRecipe() {
        let history = storageItem(
            kind: "protected_history",
            label: "Codex session history",
            path: "/Users/test/.codex/sessions",
            cleanupID: ""
        )

        XCTAssertFalse(history.canCleanup)
    }

    func testCleanupPreviewParsesApprovalProtocol() throws {
        let preview = try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tblocked
        actionMode\ttrash
        recipeId\tapp_uninstall:me.example.app
        label\tExample App
        estimatedKB\t2097152
        blockedReason\t앱을 먼저 종료하세요.
        runningProcesses\t/Applications/Example App.app/Contents/MacOS/ExampleApp
        target\t/Applications/Example App.app
        target\t/Users/test/Library/Caches/me.example.app
        """))

        XCTAssertEqual(preview.statusText, "먼저 종료할 작업이 있습니다")
        XCTAssertEqual(preview.estimatedText, "2.0GB")
        XCTAssertEqual(preview.targets.count, 2)
        XCTAssertFalse(preview.canExecute)
    }

    func testCleanupPresentationExplainsFreshMeasurementAndCompactsProcesses() {
        XCTAssertNil(CleanupPresentation.sizeChangeNotice(
            snapshotAge: "1시간 전 검사",
            scannedSize: "13.3GB",
            previewSize: "13.3GB"
        ))
        XCTAssertEqual(
            CleanupPresentation.sizeChangeNotice(
                snapshotAge: "1시간 전 검사",
                scannedSize: "13.3GB",
                previewSize: "16.0GB"
            ),
            "1시간 전 검사 값은 13.3GB였고, 미리보기에서 16.0GB로 다시 측정했습니다."
        )

        let processes = CleanupPresentation.processDisplays(from: [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --token=do-not-expose",
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework",
            "node /tmp/airmcp server.mjs",
            "node /tmp/airmcp another.mjs",
        ].joined(separator: ";"))

        XCTAssertEqual(processes.map(\.name), ["Google Chrome", "AirMCP"])

        let pidEvidence = CleanupPresentation.processDisplays(
            from: "Node/npm · PID 6095;Node/npm · PID 6161"
        )
        XCTAssertEqual(pidEvidence.map(\.name), ["Node/npm · PID 6095", "Node/npm · PID 6161"])
    }

    func testBlockedPreviewWithoutMeasurementDefersEstimateDisplay() throws {
        let preview = try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tblocked
        recipeId\tcodex_runtime_cache
        label\tCodex runtime cache
        estimatedKB\t0
        estimateMeasured\tfalse
        blockedReason\tCodex 앱과 진행 중인 Codex 작업을 먼저 종료하세요.
        """))

        XCTAssertFalse(preview.estimateMeasured)
        XCTAssertEqual(preview.estimatedText, "측정 보류")
        XCTAssertFalse(preview.canExecute)

        let legacyBlocked = try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tblocked
        recipeId\tcodex_runtime_cache
        label\tCodex runtime cache
        estimatedKB\t0
        """))

        XCTAssertFalse(legacyBlocked.estimateMeasured)
        XCTAssertEqual(legacyBlocked.estimatedText, "측정 보류")

        let measuredReady = try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tready
        recipeId\tnpm_cache
        label\tnpm cache
        estimatedKB\t1048576
        estimateMeasured\ttrue
        """))

        XCTAssertTrue(measuredReady.estimateMeasured)
        XCTAssertEqual(measuredReady.estimatedText, "1.0GB")
    }

    func testCleanupPresentationExplainsDeferredMeasurement() {
        XCTAssertEqual(
            CleanupPresentation.sizeChangeNotice(
                snapshotAge: "2분 전 검사",
                scannedSize: "1.5GB",
                previewSize: "측정 보류",
                estimateMeasured: false
            ),
            "2분 전 검사 값은 1.5GB였습니다. 먼저 종료할 작업이 있어 아직 다시 측정하지 않았습니다. 종료 후 '다시 확인'을 누르면 다시 측정합니다."
        )
        XCTAssertEqual(
            CleanupPresentation.sizeChangeNotice(
                snapshotAge: "2분 전 검사",
                scannedSize: nil,
                previewSize: "측정 보류",
                estimateMeasured: false
            ),
            "먼저 종료할 작업이 있어 아직 크기를 측정하지 않았습니다. 종료 후 '다시 확인'을 누르면 측정합니다."
        )
    }

    func testSimulatorSelectionUsesUUID() throws {
        let first = try XCTUnwrap(SimulatorDevice(json: simulatorJSON(name: "iPhone 17 Pro")))
        let renamed = try XCTUnwrap(SimulatorDevice(json: simulatorJSON(name: "QA Phone")))

        XCTAssertEqual(first.id, renamed.id)
        XCTAssertTrue(first.isBooted)
    }

    func testBundledRuntimeInstallMigratesUserConfigOutsideRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-runtime-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundle/runtime")
        let destination = root.appendingPathComponent("support/runtime")

        try writeRuntime(at: source, manifest: "new", config: "default")
        try writeRuntime(at: destination, manifest: "old", config: "custom")
        try "new rule".write(
            to: source.appendingPathComponent("rules/process.json"),
            atomically: true,
            encoding: .utf8
        )

        try RuntimeWorkspace.installBundledRuntime(from: source, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("runtime-manifest.txt")),
            "new"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("data/config.json")),
            "default"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.deletingLastPathComponent().appendingPathComponent("config.json")),
            "custom"
        )
        XCTAssertTrue(RuntimeWorkspace.hasScanner(at: destination))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("rules/process.json").path
        ))
    }

    func testRuntimeResolutionFallsBackToBundledRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-runtime-resolve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let bundled = resources.appendingPathComponent("runtime")
        let support = root.appendingPathComponent("support")
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try writeRuntime(at: bundled, manifest: "bundle", config: "default")

        let resolved = RuntimeWorkspace.resolve(
            environment: [:],
            resourceURL: resources,
            currentDirectory: unrelated,
            applicationSupportRoot: support
        )

        XCTAssertEqual(
            resolved.standardizedFileURL,
            support.appendingPathComponent("Modore/results").standardizedFileURL
        )
        XCTAssertTrue(RuntimeWorkspace.hasScanner(
            at: support.appendingPathComponent("Modore/runtime")
        ))
    }

    func testDevelopmentEnvironmentAcceptsSourceScannerWithoutExecutableBit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-runtime-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("checkout")
        try writeRuntime(at: source, manifest: "source", config: "default")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: source.appendingPathComponent("scripts/scanner.sh").path
        )
        let resolved = RuntimeWorkspace.resolve(
            environment: [
                "PCH_DEVELOPMENT_MODE": "1",
                "PCH_PROJECT_DIR": source.path,
            ],
            resourceURL: nil,
            currentDirectory: root.appendingPathComponent("unrelated"),
            applicationSupportRoot: root.appendingPathComponent("support")
        )

        XCTAssertEqual(resolved.standardizedFileURL, source.standardizedFileURL)
    }

    func testBundledRuntimeRefreshesTamperedScriptAndMigratesConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-runtime-integrity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundle/runtime")
        let destination = root.appendingPathComponent("support/runtime")
        try writeRuntime(at: source, manifest: "same", config: "default")

        try RuntimeWorkspace.installBundledRuntime(from: source, to: destination)
        try "custom".write(
            to: destination.appendingPathComponent("data/config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/bash\nexit 99\n".write(
            to: destination.appendingPathComponent("scripts/scanner.sh"),
            atomically: true,
            encoding: .utf8
        )

        try RuntimeWorkspace.installBundledRuntime(from: source, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("scripts/scanner.sh")),
            "#!/bin/bash\nexit 0\n"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("data/config.json")),
            "default"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.deletingLastPathComponent().appendingPathComponent("config.json")),
            "custom"
        )
    }

    private func storageItem(
        kind: String = "cache",
        label: String = "Cache",
        path: String,
        cleanupID: String
    ) -> StorageItem {
        StorageItem(json: storageJSON(
            kind: kind,
            label: label,
            sizeGB: 1,
            path: path,
            cleanupID: cleanupID
        ))!
    }

    private func volume(freeGB: Double = 30) -> [String: Any] {
        [
            "mount": "/",
            "freeGB": freeGB,
            "usedGB": 70,
            "totalGB": 100,
            "usePercent": 70,
            "risk": "safe",
        ]
    }

    private func storageJSON(
        kind: String = "cache",
        label: String,
        sizeGB: Double,
        path: String,
        measureStatus: String = "ok",
        cleanupID: String = ""
    ) -> [String: Any] {
        [
            "risk": "info",
            "kind": kind,
            "label": label,
            "sizeGB": sizeGB,
            "path": path,
            "action": "확인",
            "note": "테스트 항목",
            "measureStatus": measureStatus,
            "cleanupId": cleanupID,
        ]
    }

    private func simulatorJSON(name: String) -> [String: Any] {
        [
            "name": name,
            "uuid": "5800AF4B-90D7-4F28-A8EC-80C8E2AE4B75",
            "runtime": "iOS 26.3",
            "state": "Booted",
            "sizeGB": 2.9,
            "measureStatus": "ok",
            "protected": true,
            "protectionReason": "현재 Booted 상태",
            "cleanupId": "simulator_delete:5800AF4B-90D7-4F28-A8EC-80C8E2AE4B75",
        ]
    }

    private func writeRuntime(at root: URL, manifest: String, config: String) throws {
        let scanner = root.appendingPathComponent("scripts/scanner.sh")
        let configURL = root.appendingPathComponent("data/config.json")
        let rules = root.appendingPathComponent("rules")
        try FileManager.default.createDirectory(
            at: scanner.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try "#!/bin/bash\nexit 0\n".write(to: scanner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scanner.path)
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        try manifest.write(
            to: root.appendingPathComponent("runtime-manifest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    // 흔적 원장: 제거 대상과 "발견했지만 제거하지 않는" 항목이 절대 섞이지 않아야
    // 한다. 섞이면 승인 화면이 공유 데이터를 삭제 목록처럼 보여주게 된다.
    func testRetainedResidueNeverEntersRemovalTargets() throws {
        let protocolText = [
            "version\t1",
            "operation\tpreview",
            "status\tready",
            "actionMode\ttrash",
            "recipeId\tapp_uninstall:me.example.suite.editor",
            "label\tSuite Editor",
            "estimatedKB\t2048",
            "estimateMeasured\ttrue",
            "approvalToken\t" + String(repeating: "a", count: 64),
            "target\t/Users/example/Applications/Suite Editor.app",
            "target\t/Users/example/Library/Containers/me.example.suite.editor",
            "sharedResidue\t/Users/example/Library/Group Containers/ABCDE12345.me.example.suite",
            "reviewResidue\t/Users/example/Library/Application Support/Suite Editor",
        ].joined(separator: "\n")

        let preview = try XCTUnwrap(CleanupPreview(protocolText: protocolText))

        XCTAssertEqual(preview.targets.count, 2)
        XCTAssertEqual(preview.sharedResidue, [
            "/Users/example/Library/Group Containers/ABCDE12345.me.example.suite"
        ])
        XCTAssertEqual(preview.reviewResidue, [
            "/Users/example/Library/Application Support/Suite Editor"
        ])
        for retained in preview.sharedResidue + preview.reviewResidue {
            XCTAssertFalse(preview.targets.contains(retained))
        }
        XCTAssertTrue(preview.canExecute)
    }

    // 구버전 런타임 미러는 새 키를 보내지 않는다. 그때도 승인 흐름은 그대로 동작해야 한다.
    func testMissingResidueKeysDecodeAsEmptyLedger() throws {
        let protocolText = [
            "version\t1",
            "status\tready",
            "recipeId\tnpm_cache",
            "label\tnpm cache",
            "estimatedKB\t1024",
            "estimateMeasured\ttrue",
            "approvalToken\t" + String(repeating: "b", count: 64),
            "target\t/Users/example/.npm",
        ].joined(separator: "\n")

        let preview = try XCTUnwrap(CleanupPreview(protocolText: protocolText))

        XCTAssertTrue(preview.sharedResidue.isEmpty)
        XCTAssertTrue(preview.reviewResidue.isEmpty)
        XCTAssertTrue(preview.canExecute)
    }
}
