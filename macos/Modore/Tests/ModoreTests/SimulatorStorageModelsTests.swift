import XCTest
@testable import Modore

final class SimulatorStorageModelsTests: XCTestCase {
    func testFootprintCountsAggregateDevicesRuntimesAndSharedCacheOnce() throws {
        let snapshot = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(),
            "developerToolchains": [
                item(kind: "android_sdk", label: "Android SDK", sizeGB: 12, path: "/Developer/Android"),
                item(
                    kind: "simulator_devices",
                    label: "Simulator devices",
                    sizeGB: 21.35,
                    path: "/Developer/CoreSimulator/Devices"
                ),
                item(
                    kind: "simulator_runtime",
                    label: "iOS runtime",
                    sizeGB: 10,
                    path: "/Developer/CoreSimulator/AssetsV2/iOS"
                ),
                item(
                    kind: "simulator_runtime",
                    label: "Nested runtime metadata",
                    sizeGB: 3,
                    path: "/Developer/CoreSimulator/AssetsV2/iOS/metadata"
                ),
                item(
                    kind: "simulator_runtime",
                    label: "watchOS runtime",
                    sizeGB: 9.4,
                    path: "/Developer/CoreSimulator/AssetsV2/watchOS"
                ),
                item(
                    kind: "simulator_cache",
                    label: "Shared dyld cache",
                    sizeGB: 9.44,
                    path: "/Developer/CoreSimulator/Caches/dyld"
                ),
            ],
            // These rows are details beneath the aggregate Devices root. They
            // must not add another 21.35GB to the footprint.
            "simulatorDevices": [
                simulator(uuid: uuid(1), sizeGB: 11, createdAtEpoch: 100),
                simulator(uuid: uuid(2), sizeGB: 10.35, createdAtEpoch: 101),
            ],
        ]))

        XCTAssertEqual(snapshot.developerGB, 12, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.simulatorFootprintGB, 50.19, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.simulatorGB, 21.35, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.simulatorText, "21.4GB")
        XCTAssertEqual(snapshot.simulatorFootprintText, "50.2GB")
        XCTAssertFalse(snapshot.simulatorFootprintMeasurementIncomplete)
        XCTAssertEqual(snapshot.simulatorBreakdown.map(\.kind), [
            "simulator_devices", "simulator_runtime", "simulator_cache",
        ])
        XCTAssertEqual(snapshot.simulatorBreakdown[0].sizeGB, 21.35, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.simulatorBreakdown[1].sizeGB, 19.4, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.simulatorBreakdown[2].sizeGB, 9.44, accuracy: 0.000_001)
    }

    func testIncompleteFootprintPreservesTimedOutBytesOnlyAsConfirmedMinimum() throws {
        let snapshot = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(),
            "developerToolchains": [
                item(
                    kind: "simulator_runtime",
                    label: "Runtime",
                    sizeGB: 30,
                    path: "/Developer/CoreSimulator/AssetsV2/iOS",
                    measureStatus: "timed_out"
                ),
                item(
                    kind: "simulator_cache",
                    label: "Cache",
                    sizeGB: 1,
                    path: "/Developer/CoreSimulator/Caches/dyld"
                ),
            ],
        ]))

        XCTAssertEqual(snapshot.simulatorFootprintGB, 31, accuracy: 0.000_001)
        XCTAssertTrue(snapshot.simulatorFootprintMeasurementIncomplete)
        XCTAssertEqual(snapshot.simulatorFootprintText, "31.0GB+")
        XCTAssertEqual(snapshot.simulatorBreakdown.first?.sizeText, "30.0GB+")
    }

    func testPartialDeviceAggregateIsPresentedOnlyAsAConfirmedMinimum() throws {
        let snapshot = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(),
            "developerToolchains": [
                item(
                    kind: "simulator_devices",
                    label: "Partially measured devices",
                    sizeGB: 7,
                    path: "/Developer/CoreSimulator/Devices",
                    measureStatus: "timed_out"
                ),
                item(
                    kind: "simulator_cache",
                    label: "Cache",
                    sizeGB: 1,
                    path: "/Developer/CoreSimulator/Caches/dyld"
                ),
            ],
        ]))

        XCTAssertEqual(snapshot.simulatorGB, 7, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.simulatorFootprintGB, 8, accuracy: 0.000_001)
        XCTAssertTrue(snapshot.simulatorFootprintMeasurementIncomplete)
        XCTAssertEqual(snapshot.simulatorText, "7.0GB+")
        XCTAssertEqual(snapshot.simulatorFootprintText, "8.0GB+")
    }

    func testPartialDeviceRowShowsAConfirmedMinimumWhenBytesWerePreserved() throws {
        let partial = try XCTUnwrap(SimulatorDevice(json: simulator(
            uuid: uuid(1),
            sizeGB: 1.25,
            measureStatus: "timed_out",
            createdAtEpoch: 1_000
        )))
        let smallPartial = try XCTUnwrap(SimulatorDevice(json: simulator(
            uuid: uuid(2),
            sizeGB: 0.05,
            measureStatus: "timed_out",
            createdAtEpoch: 1_001
        )))
        let unknown = try XCTUnwrap(SimulatorDevice(json: simulator(
            uuid: uuid(3),
            sizeGB: 0,
            measureStatus: "timed_out",
            createdAtEpoch: 1_002
        )))

        XCTAssertEqual(partial.sizeText, "최소 1.2GB")
        XCTAssertEqual(smallPartial.sizeText, "최소 51.2MB")
        XCTAssertEqual(unknown.sizeText, "측정 보류")
    }

    func testLegacyZeroTimedOutAggregateFallsBackToMeasuredUUIDRows() throws {
        let snapshot = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(),
            "developerToolchains": [
                item(
                    kind: "simulator_devices",
                    label: "Legacy timed out aggregate",
                    sizeGB: 0,
                    path: "/Users/test/Library/Developer/CoreSimulator/Devices",
                    measureStatus: "timed_out"
                ),
            ],
            "simulatorDevices": [
                simulator(uuid: uuid(1), sizeGB: 4, createdAtEpoch: 1_000),
                simulator(uuid: uuid(2), sizeGB: 3, createdAtEpoch: 1_001),
                simulator(uuid: uuid(3), sizeGB: 0, createdAtEpoch: 1_002),
            ],
        ]))

        XCTAssertEqual(snapshot.simulatorGB, 7, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.simulatorFootprintGB, 7, accuracy: 0.000_001)
        XCTAssertFalse(snapshot.simulatorFootprintMeasurementIncomplete)
        XCTAssertEqual(snapshot.simulatorText, "7.0GB")
    }

    func testDeviceParsesCreationEvidenceAndBurstDoesNotClaimACreator() throws {
        let devices = try [
            simulator(uuid: uuid(1), runtime: "iOS 27", createdAtEpoch: 1_000),
            simulator(uuid: uuid(2), runtime: "iOS 27", createdAtEpoch: 1_003),
            simulator(uuid: uuid(3), runtime: "iOS 27", createdAtEpoch: 1_005),
            // Three devices whose total span exceeds the five-second window
            // are not one burst even when adjacent pairs are close.
            simulator(uuid: uuid(4), runtime: "watchOS 27", createdAtEpoch: 2_000),
            simulator(uuid: uuid(5), runtime: "watchOS 27", createdAtEpoch: 2_003),
            simulator(uuid: uuid(6), runtime: "watchOS 27", createdAtEpoch: 2_006),
            simulator(uuid: uuid(7), runtime: "iOS 27", createdAtEpoch: 0),
        ].map { try XCTUnwrap(SimulatorDevice(json: $0)) }

        XCTAssertEqual(
            devices[0].path,
            "/Users/test/Library/Developer/CoreSimulator/Devices/\(uuid(1))"
        )
        XCTAssertEqual(devices[0].createdAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(devices[6].createdAt)

        let bursts = SimulatorCreationBurst.detect(in: devices)

        XCTAssertEqual(bursts.count, 1)
        XCTAssertEqual(bursts[0].runtime, "iOS 27")
        XCTAssertEqual(bursts[0].count, 3)
        XCTAssertEqual(bursts[0].createdAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(bursts[0].endedAt, Date(timeIntervalSince1970: 1_005))
        XCTAssertNil(bursts[0].creator)
        XCTAssertEqual(bursts[0].creatorText, "생성 주체 미확정")
    }

    func testBurstChoosesLargestOverlappingWindow() throws {
        let timestamps: [Double] = [1_000, 1_004, 1_005, 1_008, 1_009]
        let devices = try timestamps.enumerated().map { index, createdAt in
            try XCTUnwrap(SimulatorDevice(json: simulator(
                uuid: uuid(index + 1),
                runtime: "iOS 27",
                createdAtEpoch: createdAt
            )))
        }

        let bursts = SimulatorCreationBurst.detect(in: devices)

        XCTAssertEqual(bursts.count, 1)
        XCTAssertEqual(bursts[0].count, 4)
        XCTAssertEqual(bursts[0].createdAt, Date(timeIntervalSince1970: 1_004))
        XCTAssertEqual(bursts[0].endedAt, Date(timeIntervalSince1970: 1_009))
    }

    func testHistoryTracksMeasuredSimulatorGrowthByUUID() throws {
        let identifier = uuid(1)
        let before = try snapshot(simulatorRows: [
            simulator(uuid: identifier, sizeGB: 1, createdAtEpoch: 1_000),
        ])
        let after = try snapshot(simulatorRows: [
            simulator(uuid: identifier, sizeGB: 2.5, createdAtEpoch: 1_000),
        ])
        let beforeEntry = StorageHistoryEntry(
            sourceID: "before",
            capturedAt: Date(timeIntervalSince1970: 1),
            storage: before
        )
        let afterEntry = StorageHistoryEntry(
            sourceID: "after",
            capturedAt: Date(timeIntervalSince1970: 2),
            storage: after
        )

        let historyRow = try XCTUnwrap(afterEntry.items.first { $0.kind == "simulator_device" })
        XCTAssertTrue(historyRow.key.contains(identifier))
        XCTAssertEqual(historyRow.category, "simulator_detail")
        XCTAssertEqual(historyRow.path, after.simulatorDevices[0].path)

        let change = try XCTUnwrap(
            StorageChangeSummary(entries: [beforeEntry, afterEntry]).flatMap {
                $0.itemChanges.first { $0.key == historyRow.key }
            }
        )
        XCTAssertEqual(change.deltaGB, 1.5, accuracy: 0.000_001)
        XCTAssertTrue(change.hasMeasuredEndpoints)
    }

    func testHistoryDoesNotDoubleCountDeviceAggregateAndUUIDRows() throws {
        let identifier = uuid(1)
        func storage(deviceGB: Double) throws -> StorageSnapshot {
            try XCTUnwrap(StorageSnapshot(json: [
                "volume": volume(),
                "developerToolchains": [
                    item(
                        kind: "simulator_devices",
                        label: "Simulator devices",
                        sizeGB: deviceGB,
                        path: "/Users/test/Library/Developer/CoreSimulator/Devices"
                    ),
                ],
                "simulatorDevices": [
                    simulator(
                        uuid: identifier,
                        sizeGB: deviceGB,
                        createdAtEpoch: 1_000
                    ),
                ],
            ]))
        }

        let before = StorageHistoryEntry(
            sourceID: "before",
            capturedAt: Date(timeIntervalSince1970: 1),
            storage: try storage(deviceGB: 1)
        )
        let after = StorageHistoryEntry(
            sourceID: "after",
            capturedAt: Date(timeIntervalSince1970: 2),
            storage: try storage(deviceGB: 2.5)
        )
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [before, after]))

        XCTAssertFalse(after.items.contains {
            $0.category == "developer" && $0.kind.hasPrefix("simulator_")
        })
        XCTAssertEqual(summary.itemChanges.filter { $0.category == "simulator" }.count, 1)
        XCTAssertEqual(summary.itemChanges.filter { $0.category == "simulator_detail" }.count, 1)
        XCTAssertEqual(summary.observedGrowthGB, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(summary.trackedNetDeltaGB, 1.5, accuracy: 0.000_001)
    }

    func testHistoryCountsOrphanGrowthFromDevicesAggregate() throws {
        func storage(deviceGB: Double, knownDeviceGB: Double, freeGB: Double) throws -> StorageSnapshot {
            try XCTUnwrap(StorageSnapshot(json: [
                "volume": volume(freeGB: freeGB),
                "developerToolchains": [
                    item(
                        kind: "simulator_devices",
                        label: "Simulator devices",
                        sizeGB: deviceGB,
                        path: "/Users/test/Library/Developer/CoreSimulator/Devices"
                    ),
                ],
                "simulatorDevices": [
                    simulator(
                        uuid: uuid(1),
                        sizeGB: knownDeviceGB,
                        createdAtEpoch: 1_000
                    ),
                ],
            ]))
        }

        let before = StorageHistoryEntry(
            sourceID: "before",
            capturedAt: Date(timeIntervalSince1970: 1),
            storage: try storage(deviceGB: 3, knownDeviceGB: 1, freeGB: 30)
        )
        let after = StorageHistoryEntry(
            sourceID: "after",
            capturedAt: Date(timeIntervalSince1970: 2),
            storage: try storage(deviceGB: 5, knownDeviceGB: 1, freeGB: 28)
        )
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [before, after]))

        XCTAssertEqual(summary.itemChanges.count, 1)
        XCTAssertEqual(summary.observedGrowthGB, 2, accuracy: 0.000_001)
        XCTAssertEqual(summary.trackedNetDeltaGB, 2, accuracy: 0.000_001)
        XCTAssertEqual(summary.primaryCause?.label, "Simulator devices")
    }

    func testHistoryRetainsDisjointSimulatorRuntimeAndCacheGrowth() throws {
        func storage(runtimeGB: Double, cacheGB: Double) throws -> StorageSnapshot {
            try XCTUnwrap(StorageSnapshot(json: [
                "volume": volume(),
                "developerToolchains": [
                    item(
                        kind: "simulator_runtime",
                        label: "iOS runtime",
                        sizeGB: runtimeGB,
                        path: "/System/Library/AssetsV2/iOS-runtime"
                    ),
                    item(
                        kind: "simulator_cache",
                        label: "dyld cache",
                        sizeGB: cacheGB,
                        path: "/Library/Developer/CoreSimulator/Caches/dyld"
                    ),
                ],
            ]))
        }
        let before = StorageHistoryEntry(
            sourceID: "before",
            capturedAt: Date(timeIntervalSince1970: 1),
            storage: try storage(runtimeGB: 10, cacheGB: 2)
        )
        let after = StorageHistoryEntry(
            sourceID: "after",
            capturedAt: Date(timeIntervalSince1970: 2),
            storage: try storage(runtimeGB: 19, cacheGB: 3)
        )
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [before, after]))

        XCTAssertEqual(summary.itemChanges.filter {
            $0.category == "simulator"
        }.count, 2)
        XCTAssertEqual(summary.observedGrowthGB, 10, accuracy: 0.000_001)
        XCTAssertEqual(summary.trackedNetDeltaGB, 10, accuracy: 0.000_001)
    }

    func testHistoryMigratesLegacyDeveloperSimulatorCategoryWithoutFalseDelta() throws {
        let rows: [(String, String, Double)] = [
            ("simulator_devices", "/Developer/CoreSimulator/Devices", 21),
            ("simulator_runtime", "/Developer/CoreSimulator/AssetsV2/iOS", 19),
            ("simulator_cache", "/Developer/CoreSimulator/Caches/dyld", 9),
        ]
        let legacyItems = rows.map { kind, path, sizeGB in
            StorageHistoryItem(
                key: "developer|\(kind)|\(path)",
                label: kind,
                category: "developer",
                kind: kind,
                sizeGB: sizeGB,
                path: path,
                cleanupID: "",
                measureStatus: "ok"
            )
        }
        let currentStorage = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(),
            "developerToolchains": rows.map { kind, path, sizeGB in
                item(kind: kind, label: kind, sizeGB: sizeGB, path: path)
            },
        ]))
        let legacy = StorageHistoryEntry(
            sourceID: "legacy",
            capturedAt: Date(timeIntervalSince1970: 1),
            freeGB: 30,
            usedGB: 70,
            totalGB: 100,
            items: legacyItems
        )
        let current = StorageHistoryEntry(
            sourceID: "current",
            capturedAt: Date(timeIntervalSince1970: 2),
            storage: currentStorage
        )

        let summary = try XCTUnwrap(StorageChangeSummary(entries: [legacy, current]))

        XCTAssertTrue(summary.itemChanges.isEmpty)
        XCTAssertEqual(summary.observedGrowthGB, 0, accuracy: 0.000_001)
        XCTAssertEqual(summary.observedShrinkGB, 0, accuracy: 0.000_001)
        XCTAssertEqual(summary.trackedNetDeltaGB, 0, accuracy: 0.000_001)
    }

    func testHistoryDoesNotCallAnInventoryShapeUpgradeMeasuredGrowth() throws {
        let legacyRuntimePath = "/System/Library/AssetsV2/iOS-runtime"
        let legacyItems = [
            StorageHistoryItem(
                key: "developer|simulator_runtime|\(legacyRuntimePath)",
                label: "iOS runtime",
                category: "developer",
                kind: "simulator_runtime",
                sizeGB: 19,
                path: legacyRuntimePath,
                cleanupID: "",
                measureStatus: "ok"
            ),
            StorageHistoryItem(
                key: "developer|simulator_cache|/Library/Developer/CoreSimulator/Caches",
                label: "Legacy CoreSimulator cache",
                category: "developer",
                kind: "simulator_cache",
                sizeGB: 9,
                path: "/Library/Developer/CoreSimulator/Caches",
                cleanupID: "",
                measureStatus: "ok"
            ),
        ]
        let currentStorage = try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(freeGB: 20),
            "developerToolchains": [
                item(
                    kind: "simulator_runtime",
                    label: "iOS runtime",
                    sizeGB: 19,
                    path: legacyRuntimePath
                ),
                item(
                    kind: "simulator_runtime",
                    label: "watchOS runtime",
                    sizeGB: 5,
                    path: "/System/Library/AssetsV2/watchOS-runtime"
                ),
                item(
                    kind: "simulator_cache",
                    label: "Shared dyld cache",
                    sizeGB: 9,
                    path: "/Library/Developer/CoreSimulator/Caches/dyld"
                ),
            ],
        ]))
        let legacy = StorageHistoryEntry(
            sourceID: "legacy",
            capturedAt: Date(timeIntervalSince1970: 1),
            freeGB: 30,
            usedGB: 70,
            totalGB: 100,
            items: legacyItems
        )
        let current = StorageHistoryEntry(
            sourceID: "current",
            capturedAt: Date(timeIntervalSince1970: 2),
            storage: currentStorage
        )

        let summary = try XCTUnwrap(StorageChangeSummary(entries: [legacy, current]))

        XCTAssertEqual(summary.itemChanges.count, 3)
        XCTAssertEqual(summary.largestChanges.count, 3)
        XCTAssertTrue(summary.growingItems.isEmpty)
        XCTAssertTrue(summary.shrinkingItems.isEmpty)
        XCTAssertNil(summary.primaryCause)
        XCTAssertTrue(summary.causeNotCaptured)
        XCTAssertEqual(summary.observedGrowthGB, 0, accuracy: 0.000_001)
        XCTAssertEqual(summary.observedShrinkGB, 0, accuracy: 0.000_001)
        XCTAssertEqual(summary.trackedNetDeltaGB, 0, accuracy: 0.000_001)
    }

    func testHistoryDoesNotInventDeltaFromTimedOutSimulatorEndpoint() throws {
        let identifier = uuid(1)
        let before = try snapshot(simulatorRows: [
            simulator(uuid: identifier, sizeGB: 1, measureStatus: "ok", createdAtEpoch: 1_000),
        ])
        let after = try snapshot(simulatorRows: [
            simulator(
                uuid: identifier,
                sizeGB: 99,
                measureStatus: "timed_out",
                createdAtEpoch: 1_000
            ),
        ])
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [
            StorageHistoryEntry(
                sourceID: "before",
                capturedAt: Date(timeIntervalSince1970: 1),
                storage: before
            ),
            StorageHistoryEntry(
                sourceID: "after",
                capturedAt: Date(timeIntervalSince1970: 2),
                storage: after
            ),
        ]))

        XCTAssertFalse(summary.itemChanges.contains { $0.key.contains(identifier) })
    }

    func testHistoryDoesNotUseRuntimeLowerBoundAsAnExactDelta() throws {
        func storage(sizeGB: Double, status: String) throws -> StorageSnapshot {
            try XCTUnwrap(StorageSnapshot(json: [
                "volume": volume(),
                "developerToolchains": [
                    item(
                        kind: "simulator_runtime",
                        label: "iOS runtime",
                        sizeGB: sizeGB,
                        path: "/System/Library/AssetsV2/iOS-runtime",
                        measureStatus: status
                    ),
                ],
            ]))
        }
        let summary = try XCTUnwrap(StorageChangeSummary(entries: [
            StorageHistoryEntry(
                sourceID: "before",
                capturedAt: Date(timeIntervalSince1970: 1),
                storage: try storage(sizeGB: 10, status: "ok")
            ),
            StorageHistoryEntry(
                sourceID: "after",
                capturedAt: Date(timeIntervalSince1970: 2),
                storage: try storage(sizeGB: 19, status: "timed_out")
            ),
        ]))

        XCTAssertTrue(summary.itemChanges.isEmpty)
        XCTAssertEqual(summary.observedGrowthGB, 0, accuracy: 0.000_001)
    }

    func testBatchGoalStillExcludesSimulatorRecipes() throws {
        let simulatorItem = try XCTUnwrap(StorageItem(json: item(
            kind: "simulator_devices",
            label: "Simulator devices",
            sizeGB: 50,
            path: "/Developer/CoreSimulator/Devices",
            cleanupID: "simulator_delete:\(uuid(1))"
        )))
        let cache = try XCTUnwrap(StorageItem(json: item(
            kind: "cache",
            label: "npm",
            sizeGB: 1,
            path: "/Users/test/.npm",
            cleanupID: "npm_cache"
        )))

        XCTAssertNil(simulatorItem.cleanupTier)
        XCTAssertEqual(
            SpaceGoalSelection.select(from: [simulatorItem, cache], targetGB: 20).map(\.label),
            ["npm"]
        )
    }

    func testTransitionalSimulatorStateIsProtectedUntilFullyShutdown() throws {
        var creatingJSON = simulator(uuid: uuid(1), createdAtEpoch: 1_000)
        creatingJSON["state"] = "Creating"
        let creating = try XCTUnwrap(SimulatorDevice(json: creatingJSON))
        let shutdown = try XCTUnwrap(SimulatorDevice(json: simulator(
            uuid: uuid(2),
            createdAtEpoch: 1_000
        )))

        XCTAssertFalse(creating.isShutdown)
        XCTAssertTrue(creating.isProtected(by: []))
        XCTAssertTrue(shutdown.isShutdown)
        XCTAssertFalse(shutdown.isProtected(by: []))
        XCTAssertTrue(shutdown.isProtected(by: [shutdown.uuid]))

        var missingStateJSON = simulator(uuid: uuid(3), createdAtEpoch: 1_000)
        missingStateJSON.removeValue(forKey: "state")
        let missingState = try XCTUnwrap(SimulatorDevice(json: missingStateJSON))
        XCTAssertEqual(missingState.state, "Unknown")
        XCTAssertFalse(missingState.isShutdown)
        XCTAssertTrue(missingState.isProtected(by: []))
    }

    private func snapshot(simulatorRows: [[String: Any]]) throws -> StorageSnapshot {
        try XCTUnwrap(StorageSnapshot(json: [
            "volume": volume(),
            "simulatorDevices": simulatorRows,
        ]))
    }

    private func volume(freeGB: Double = 30) -> [String: Any] {
        [
            "mount": "/", "freeGB": freeGB, "usedGB": 100 - freeGB,
            "totalGB": 100.0, "usePercent": 100 - freeGB, "risk": "safe",
        ]
    }

    private func item(
        kind: String,
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
            "note": "테스트",
            "measureStatus": measureStatus,
            "cleanupId": cleanupID,
        ]
    }

    private func simulator(
        uuid: String,
        runtime: String = "iOS 27",
        sizeGB: Double = 1,
        measureStatus: String = "ok",
        createdAtEpoch: Double
    ) -> [String: Any] {
        [
            "name": "Test Device \(uuid.suffix(2))",
            "uuid": uuid,
            "runtime": runtime,
            "state": "Shutdown",
            "sizeGB": sizeGB,
            "measureStatus": measureStatus,
            "cleanupId": "simulator_delete:\(uuid)",
            "createdAtEpoch": createdAtEpoch,
            "path": "/Users/test/Library/Developer/CoreSimulator/Devices/\(uuid)",
        ]
    }

    private func uuid(_ index: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", index)
    }
}
