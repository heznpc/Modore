import XCTest
@testable import PCHealthCheckMac

final class StorageSecurityRemediationTests: XCTestCase {
    func testDangerOnlySummaryContributesToUnifiedAttentionCount() throws {
        let summary = try XCTUnwrap(ScanSummary(json: [
            "overall": "danger",
            "dangerCount": 1,
            "warningCount": 0,
            "message": "위험 신호",
        ]))

        XCTAssertEqual(summary.attentionCount, 1)
        XCTAssertTrue(summary.hasDanger)
    }

    func testDuplicateCleanupRecipeUsesPathBoundHistoryIdentity() throws {
        let before = try snapshot(cleanupItems: [
            item(label: "Chrome clone X", sizeGB: 1, path: "/private/X/clone", cleanupID: "chrome"),
            item(label: "Chrome clone T", sizeGB: 2, path: "/private/T/clone", cleanupID: "chrome"),
        ])
        let after = try snapshot(cleanupItems: [
            item(label: "Chrome clone X", sizeGB: 2, path: "/private/X/clone", cleanupID: "chrome"),
            item(label: "Chrome clone T", sizeGB: 4, path: "/private/T/clone", cleanupID: "chrome"),
        ])
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [
            history("before", time: 1, storage: before),
            history("after", time: 2, storage: after),
        ]))

        XCTAssertEqual(summary.itemChanges.count, 2)
        XCTAssertEqual(Set(summary.itemChanges.map(\.key)).count, 2)
        XCTAssertEqual(summary.observedGrowthGB, 3, accuracy: 0.001)
    }

    func testNestedHistoryPathsAreNotDoubleCountedInObservedGrowth() throws {
        let before = try snapshot(cleanupItems: [
            item(label: "User caches", sizeGB: 10, path: "/cache", cleanupID: "all"),
            item(label: "Browser cache", sizeGB: 4, path: "/cache/browser", cleanupID: "browser"),
        ])
        let after = try snapshot(cleanupItems: [
            item(label: "User caches", sizeGB: 12, path: "/cache", cleanupID: "all"),
            item(label: "Browser cache", sizeGB: 5, path: "/cache/browser", cleanupID: "browser"),
        ])
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [
            history("before", time: 1, storage: before),
            history("after", time: 2, storage: after),
        ]))

        XCTAssertEqual(summary.itemChanges.count, 2)
        XCTAssertEqual(summary.observedGrowthGB, 2, accuracy: 0.001)
        XCTAssertEqual(summary.trackedNetDeltaGB, 2, accuracy: 0.001)
    }

    func testNewestHistoryEntryAfterDisplayedSnapshotIsExplicit() throws {
        let storage = try snapshot(cleanupItems: [])
        let displayed = history("displayed", time: 2, storage: storage)
        let latest = history("latest", time: 4, storage: storage)
        let entries = [
            history("older", time: 1, storage: storage),
            latest,
            displayed,
            history("newer", time: 3, storage: storage),
        ]

        XCTAssertEqual(
            StorageHistoryStore.newestEntry(after: displayed, in: entries)?.sourceID,
            latest.sourceID
        )
    }

    func testReclaimableTotalIncludesOnlyExecutableRecipes() throws {
        let storage = try snapshot(cleanupItems: [
            item(label: "Executable", sizeGB: 2, path: "/cache", cleanupID: "npm_cache"),
            item(label: "Removed broad recipe", sizeGB: 20, path: "/broad", cleanupID: "user_caches"),
            item(label: "Manual path", sizeGB: 9, path: "/private/tmp", cleanupID: ""),
        ])

        XCTAssertEqual(storage.reclaimableGB, 2, accuracy: 0.001)
        XCTAssertFalse(storage.cleanupCandidates[1].canCleanup)
    }

    func testXcodeCannotBecomeGenericApplicationCleanup() throws {
        let xcode = try XCTUnwrap(StorageItem(json: item(
            kind: "application",
            label: "Xcode",
            sizeGB: 15,
            path: "/Applications/Xcode.app",
            cleanupID: "app_uninstall:com.apple.dt.Xcode"
        )))

        XCTAssertTrue(xcode.isProtectedDeveloperApplication)
        XCTAssertFalse(xcode.canCleanup)
    }

    func testSimulatorProtectionSurvivesDeviceRenameByUUID() throws {
        let uuid = "5800AF4B-90D7-4F28-A8EC-80C8E2AE4B75"
        let first = try XCTUnwrap(SimulatorDevice(json: simulator(name: "iPhone 17", uuid: uuid)))
        let renamed = try XCTUnwrap(SimulatorDevice(json: simulator(name: "QA Phone", uuid: uuid)))

        XCTAssertTrue(first.isProtected(by: [uuid]))
        XCTAssertTrue(renamed.isProtected(by: [uuid]))
    }

    func testLegacySimulatorNameMapsEveryMatchAndKeepsUnresolvedEntryFailClosed() throws {
        let firstUUID = "5800AF4B-90D7-4F28-A8EC-80C8E2AE4B75"
        let secondUUID = "6800AF4B-90D7-4F28-A8EC-80C8E2AE4B76"
        let first = try XCTUnwrap(SimulatorDevice(json: simulator(name: "QA Phone", uuid: firstUUID)))
        let second = try XCTUnwrap(SimulatorDevice(json: simulator(name: "QA Phone", uuid: secondUUID)))
        let migration = SimulatorKeepState(
            uuids: [],
            legacyEntries: ["QA Phone", "Missing Phone"]
        ).resolvingLegacyEntries(with: [first, second])

        XCTAssertEqual(migration.uuids, [firstUUID, secondUUID])
        XCTAssertEqual(migration.unresolvedEntries, ["Missing Phone"])
    }

    func testOversizedScanResultIsReadBoundedly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-oversized-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scanURL = root.appendingPathComponent("scan_result.json")
        _ = FileManager.default.createFile(atPath: scanURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: scanURL)
        try handle.truncate(atOffset: UInt64(ScanResultLoader.maximumScanResultBytes + 1))
        try handle.close()

        let loaded = ScanResultLoader.load(
            projectRoot: root,
            historyURL: root.appendingPathComponent("history.json"),
            sampleURL: root.appendingPathComponent("samples.tsv")
        )

        XCTAssertNil(loaded.content.storage)
        XCTAssertNotNil(loaded.diagnostic)
    }

    func testOversizedSecuritySectionReportsVisibleTruncation() {
        let rows = (0...ScanContent.maximumRowsPerSection).map { index in
            ["entry": "item-\(index)", "category": "LaunchAgent", "image": "/tmp/item"]
        }
        let content = ScanContent(root: ["sections": ["autoruns": rows]])

        XCTAssertEqual(content.autorunRows.count, ScanContent.maximumRowsPerSection)
        XCTAssertTrue(content.truncatedSections.contains("자동 실행"))
    }

    private func snapshot(cleanupItems: [[String: Any]]) throws -> StorageSnapshot {
        try XCTUnwrap(StorageSnapshot(json: [
            "volume": [
                "mount": "/",
                "freeGB": 30,
                "usedGB": 70,
                "totalGB": 100,
                "usePercent": 70,
                "risk": "safe",
            ],
            "cleanupCandidates": cleanupItems,
        ]))
    }

    private func history(_ id: String, time: TimeInterval, storage: StorageSnapshot) -> StorageHistoryEntry {
        StorageHistoryEntry(
            sourceID: id,
            capturedAt: Date(timeIntervalSince1970: time),
            storage: storage
        )
    }

    private func item(
        kind: String = "cache",
        label: String,
        sizeGB: Double,
        path: String,
        cleanupID: String
    ) -> [String: Any] {
        [
            "risk": "warning",
            "kind": kind,
            "label": label,
            "sizeGB": sizeGB,
            "path": path,
            "action": "확인",
            "note": "테스트",
            "measureStatus": "ok",
            "cleanupId": cleanupID,
        ]
    }

    private func simulator(name: String, uuid: String) -> [String: Any] {
        [
            "name": name,
            "uuid": uuid,
            "runtime": "iOS 27",
            "state": "Shutdown",
            "sizeGB": 1,
            "measureStatus": "ok",
            "cleanupId": "simulator_delete:\(uuid)",
        ]
    }
}
