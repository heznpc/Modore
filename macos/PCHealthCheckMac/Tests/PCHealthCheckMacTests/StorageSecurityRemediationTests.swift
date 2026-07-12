import Darwin
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

    func testSecurityAttentionExcludesStorageAndNonAttentionFindings() throws {
        let content = ScanContent(root: [
            "summary": [
                "overall": "danger",
                "dangerCount": 2,
                "warningCount": 2,
                "message": "전체 확인 항목 4건",
            ],
            "findings": [
                ["level": "danger", "category": "process", "title": "Unknown process"],
                ["level": "warning", "category": "network", "title": "Unknown endpoint"],
                [
                    "level": "danger",
                    "category": "storage",
                    "title": "Low free space",
                    "actionTarget": "privacy",
                ],
                [
                    "level": "warning",
                    "category": "storage",
                    "title": "Growing cache",
                    "actionTarget": "development",
                ],
                ["level": "safe", "category": "process", "title": "Signed process"],
            ],
        ])

        XCTAssertEqual(content.summary?.attentionCount, 4)
        XCTAssertEqual(content.securityAttentionCount, 2)
        XCTAssertTrue(content.securityHasDanger)
        XCTAssertEqual(
            content.securityAttentionFindings.map(\.title),
            ["Unknown process", "Unknown endpoint"]
        )
        XCTAssertEqual(
            content.storageAttentionFindings.map(\.title),
            ["Low free space", "Growing cache"]
        )
        XCTAssertTrue(content.storageAttentionFindings[0].isStorageAccessFinding)
        XCTAssertTrue(content.storageAttentionFindings[1].isDevelopmentStorageFinding)
    }

    func testScanContentParsesOptionalVirusTotalSnapshot() {
        let enabled = ScanContent(root: [
            "sections": ["virustotal": ["enabled": true]],
        ])
        let disabled = ScanContent(root: [
            "sections": ["virustotal": ["enabled": false]],
        ])
        let legacy = ScanContent(root: ["sections": [:]])

        XCTAssertEqual(enabled.virusTotalEnabled, true)
        XCTAssertEqual(disabled.virusTotalEnabled, false)
        XCTAssertNil(legacy.virusTotalEnabled)
    }

    func testFreeSpaceLossUsesNewlyAppearedGrowthInsteadOfLargerDisappearance() throws {
        let before = try snapshot(
            freeGB: 30,
            cleanupItems: [
                item(label: "Disappeared archive", sizeGB: 6, path: "/old", cleanupID: "old"),
            ]
        )
        let after = try snapshot(
            freeGB: 29,
            cleanupItems: [
                item(label: "New cache", sizeGB: 2, path: "/new", cleanupID: "new"),
            ]
        )
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [
            history("before", time: 1, storage: before),
            history("after", time: 2, storage: after),
        ]))

        XCTAssertEqual(summary.primaryCause?.label, "New cache")
        XCTAssertEqual(summary.primaryCause?.beforeGB, 0)
        XCTAssertEqual(summary.primaryCause?.afterGB, 2)
        XCTAssertEqual(summary.primaryCause?.appearedInTrackedList, true)
        XCTAssertEqual(summary.oppositeDirectionChanges.first?.label, "Disappeared archive")
        XCTAssertEqual(summary.oppositeDirectionChanges.first?.afterGB, 0)
        XCTAssertEqual(summary.oppositeDirectionChanges.first?.disappearedFromTrackedList, true)
        XCTAssertEqual(summary.observedGrowthGB, 0)
        XCTAssertEqual(summary.unattributedConsumedGB, 1, accuracy: 0.001)
        XCTAssertFalse(summary.causeNotCaptured)
    }

    func testFreeSpaceRecoveryUsesDisappearedPathInsteadOfNewGrowth() throws {
        let before = try snapshot(
            freeGB: 20,
            cleanupItems: [
                item(label: "Removed cache", sizeGB: 4, path: "/removed", cleanupID: "removed"),
            ]
        )
        let after = try snapshot(
            freeGB: 23,
            cleanupItems: [
                item(label: "New SDK", sizeGB: 8, path: "/new-sdk", cleanupID: "new-sdk"),
            ]
        )
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [
            history("before", time: 1, storage: before),
            history("after", time: 2, storage: after),
        ]))

        XCTAssertEqual(summary.primaryCause?.label, "Removed cache")
        XCTAssertEqual(summary.primaryCause?.beforeGB, 4)
        XCTAssertEqual(summary.primaryCause?.afterGB, 0)
        XCTAssertEqual(summary.primaryCause?.disappearedFromTrackedList, true)
        XCTAssertEqual(summary.oppositeDirectionChanges.first?.label, "New SDK")
        XCTAssertEqual(summary.oppositeDirectionChanges.first?.beforeGB, 0)
        XCTAssertEqual(summary.oppositeDirectionChanges.first?.appearedInTrackedList, true)
        XCTAssertEqual(summary.observedShrinkGB, 0)
        XCTAssertEqual(summary.unattributedRecoveredGB, 3, accuracy: 0.001)
        XCTAssertFalse(summary.causeNotCaptured)
    }

    func testDirectionWithoutMatchingPathEvidenceIsExplicitlyUncaptured() throws {
        let before = try snapshot(
            freeGB: 30,
            cleanupItems: [
                item(label: "Shrinking cache", sizeGB: 5, path: "/cache", cleanupID: "cache"),
            ]
        )
        let after = try snapshot(
            freeGB: 29,
            cleanupItems: [
                item(label: "Shrinking cache", sizeGB: 2, path: "/cache", cleanupID: "cache"),
            ]
        )
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [
            history("before", time: 1, storage: before),
            history("after", time: 2, storage: after),
        ]))

        XCTAssertNil(summary.primaryCause)
        XCTAssertTrue(summary.causeNotCaptured)
        XCTAssertEqual(summary.oppositeDirectionChanges.first?.label, "Shrinking cache")
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

    func testProtectedStoragePresentationCollapsesSmallRowsButKeepsDeferredMeasurementsVisible() throws {
        let items = try [
            XCTUnwrap(StorageItem(json: item(
                label: "Large history",
                sizeGB: 0.02,
                path: "/history/large",
                cleanupID: ""
            ))),
            XCTUnwrap(StorageItem(json: item(
                label: "Small index",
                sizeGB: 0.001,
                path: "/history/index",
                cleanupID: ""
            ))),
            XCTUnwrap(StorageItem(json: item(
                label: "Deferred database",
                sizeGB: 0,
                path: "/history/deferred",
                cleanupID: "",
                measureStatus: "timed_out"
            ))),
        ]

        let groups = ProtectedStoragePresentation.split(items)

        XCTAssertEqual(groups.prominent.map(\.label), ["Large history", "Deferred database"])
        XCTAssertEqual(groups.small.map(\.label), ["Small index"])
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
        XCTAssertTrue(loaded.diagnostic?.contains("32MB 제한") == true)
    }

    func testScanResultLoaderRejectsSymlinkAndFIFOWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-unsafe-scan-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scanURL = root.appendingPathComponent("scan_result.json")
        let target = root.appendingPathComponent("target.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: scanURL, withDestinationURL: target)

        let symlinked = ScanResultLoader.load(
            projectRoot: root,
            historyURL: root.appendingPathComponent("history.json"),
            sampleURL: root.appendingPathComponent("samples.tsv")
        )
        XCTAssertNil(symlinked.content.storage)
        XCTAssertNotNil(symlinked.diagnostic)

        try FileManager.default.removeItem(at: scanURL)
        let fifoStatus = scanURL.path.withCString { Darwin.mkfifo($0, 0o600) }
        XCTAssertEqual(fifoStatus, 0)
        let started = Date()
        let fifo = ScanResultLoader.load(
            projectRoot: root,
            historyURL: root.appendingPathComponent("history.json"),
            sampleURL: root.appendingPathComponent("samples.tsv")
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNil(fifo.content.storage)
        XCTAssertNotNil(fifo.diagnostic)
    }

    func testVirusTotalConsentConfigRejectsSymlinkAndFIFOWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-unsafe-vt-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = root.appendingPathComponent("config.json")
        let target = root.appendingPathComponent("target.json")
        try #"{"virustotal":{"enabled":true}}"#.write(
            to: target,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: configuration, withDestinationURL: target)

        var environment = ScanPipeline.scanEnvironment(
            configurationURL: configuration,
            processEnvironment: ["VT_API_KEY": "secret"]
        )
        XCTAssertNil(environment["VT_API_KEY"])

        try FileManager.default.removeItem(at: configuration)
        let fifoStatus = configuration.path.withCString { Darwin.mkfifo($0, 0o600) }
        XCTAssertEqual(fifoStatus, 0)
        let started = Date()
        environment = ScanPipeline.scanEnvironment(
            configurationURL: configuration,
            processEnvironment: ["VT_API_KEY": "secret"]
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNil(environment["VT_API_KEY"])
    }

    func testScanResultReadRejectsReplacedParentIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-scan-parent-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current")
        let replacement = root.appendingPathComponent("replacement")
        let old = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try "{}".write(
            to: replacement.appendingPathComponent("scan_result.json"),
            atomically: true,
            encoding: .utf8
        )
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: current))
        try FileManager.default.moveItem(at: current, to: old)
        try FileManager.default.moveItem(at: replacement, to: current)

        XCTAssertThrowsError(try ScanResultLoader.boundedData(
            contentsOf: current.appendingPathComponent("scan_result.json"),
            maximumBytes: ScanResultLoader.maximumScanResultBytes,
            expectedParentIdentity: identity
        ))
    }

    func testStorageHistoryRejectsSymlinkAndFIFOInputs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-unsafe-history-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let historyURL = root.appendingPathComponent("history.json")
        let target = root.appendingPathComponent("target.json")
        try "sentinel".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: historyURL, withDestinationURL: target)

        XCTAssertEqual(StorageHistoryStore.load(from: historyURL), [])
        let entry = StorageHistoryEntry(
            sourceID: "unsafe-history",
            capturedAt: Date(timeIntervalSince1970: 1),
            storage: try snapshot(cleanupItems: [])
        )
        XCTAssertThrowsError(try StorageHistoryStore.record(entry, at: historyURL))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel")

        try FileManager.default.removeItem(at: historyURL)
        let fifoStatus = historyURL.path.withCString { Darwin.mkfifo($0, 0o600) }
        XCTAssertEqual(fifoStatus, 0)
        let started = Date()
        XCTAssertEqual(StorageHistoryStore.load(from: historyURL), [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testSecureLocalFileWriteRejectsReplacedParentIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-history-parent-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current")
        let replacement = root.appendingPathComponent("replacement")
        let old = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: current))
        try FileManager.default.moveItem(at: current, to: old)
        try FileManager.default.moveItem(at: replacement, to: current)
        let destination = current.appendingPathComponent("history.json")

        XCTAssertThrowsError(try SecureLocalFileIO.atomicWrite(
            Data("[]".utf8),
            to: destination,
            expectedParentIdentity: identity
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testGeneratedReportIsRepublishedWithOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-private-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let report = root.appendingPathComponent("report.html")
        try Data("<html>private</html>".utf8).write(to: report)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: report.path
        )
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))

        XCTAssertTrue(ScanPipeline.finalizeGeneratedReport(
            at: report,
            expectedParentIdentity: identity
        ))
        XCTAssertEqual(
            try Data(contentsOf: report),
            Data("<html>private</html>".utf8)
        )
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: report.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testOversizedSecuritySectionReportsVisibleTruncation() {
        let rows = (0...ScanContent.maximumRowsPerSection).map { index in
            ["entry": "item-\(index)", "category": "LaunchAgent", "image": "/tmp/item"]
        }
        let content = ScanContent(root: ["sections": ["autoruns": rows]])

        XCTAssertEqual(content.autorunRows.count, ScanContent.maximumRowsPerSection)
        XCTAssertTrue(content.truncatedSections.contains("자동 실행"))
    }

    func testHistoryWritePayloadPrunesBeforeSixteenMegabyteReadLimit() throws {
        let repeated = String(repeating: "x", count: 1_500)
        let items = (0..<2_000).map { index in
            StorageHistoryItem(
                key: "item-\(index)",
                label: repeated,
                category: "cleanup",
                kind: "cache",
                sizeGB: Double(index),
                path: "/history/\(index)/\(repeated)",
                cleanupID: "cache-\(index)",
                measureStatus: "ok"
            )
        }
        let entries = (0..<3).map { index in
            StorageHistoryEntry(
                sourceID: "entry-\(index)",
                capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                freeGB: 30,
                usedGB: 70,
                totalGB: 100,
                items: items,
                incidentKind: "browser_automation",
                incidentTitle: "Browser automation residue",
                incidentValue: "1 root",
                collectionComplete: false,
                browserVerdict: "orphaned"
            )
        }

        let payload = try StorageHistoryStore.encodedHistoryForWrite(entries)

        XCTAssertLessThanOrEqual(payload.data.count, StorageHistoryStore.maximumHistoryBytes)
        XCTAssertEqual(payload.entries.map(\.sourceID), ["entry-1", "entry-2"])
        XCTAssertTrue(payload.entries.allSatisfy { entry in
            entry.incidentKind == "browser_automation"
                && entry.incidentTitle == "Browser automation residue"
                && entry.incidentValue == "1 root"
                && entry.collectionComplete == false
                && entry.browserVerdict == "orphaned"
        })

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-history-byte-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let historyURL = root.appendingPathComponent("history.json")
        try payload.data.write(to: historyURL)

        XCTAssertEqual(
            StorageHistoryStore.load(from: historyURL).map(\.sourceID),
            ["entry-1", "entry-2"]
        )
    }

    private func snapshot(
        freeGB: Double = 30,
        cleanupItems: [[String: Any]]
    ) throws -> StorageSnapshot {
        try XCTUnwrap(StorageSnapshot(json: [
            "volume": [
                "mount": "/",
                "freeGB": freeGB,
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
        cleanupID: String,
        measureStatus: String = "ok"
    ) -> [String: Any] {
        [
            "risk": "warning",
            "kind": kind,
            "label": label,
            "sizeGB": sizeGB,
            "path": path,
            "action": "확인",
            "note": "테스트",
            "measureStatus": measureStatus,
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
