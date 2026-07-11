import XCTest
@testable import PCHealthCheckMac

final class PCHealthCheckMacTests: XCTestCase {
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
                "cpu": [["risk": "safe", "name": "kernel_task", "pid": 1, "cpu": 0.1]],
            ],
        ])

        XCTAssertEqual(content.summary?.warningCount, 1)
        XCTAssertEqual(content.findings.count, 1)
        XCTAssertEqual(content.cpuRows.count, 1)
        XCTAssertNotNil(content.storage)
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

    func testMissingHistoryRowsAreNotReportedAsDeleted() throws {
        let previous = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(freeGB: 30),
            "cleanupCandidates": [
                storageJSON(label: "Growing", sizeGB: 2, path: "/growing", cleanupID: "growing"),
                storageJSON(label: "Timed scan row", sizeGB: 5, path: "/missing", cleanupID: "missing"),
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
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework",
            "node /tmp/airmcp server.mjs",
            "node /tmp/airmcp another.mjs",
        ].joined(separator: ";"))

        XCTAssertEqual(processes.map(\.name), ["Google Chrome", "AirMCP"])
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
            support.appendingPathComponent("PC Health Check/runtime").standardizedFileURL
        )
        XCTAssertTrue(RuntimeWorkspace.hasScanner(at: resolved))
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
}
