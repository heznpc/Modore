import Foundation
import ModoreDomain
import XCTest
@testable import Modore

final class LiveStateTests: XCTestCase {
    private let gibibyte: Int64 = 1_073_741_824

    func testFreeSpaceObservationCarriesValueTimeAndSource() throws {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = try XCTUnwrap(
            LiveStateService.observeFreeSpace(observedAt: observedAt)
        )

        XCTAssertGreaterThan(observation.value.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(observation.value.freeBytes, 0)
        XCTAssertLessThanOrEqual(
            observation.value.freeBytes,
            observation.value.totalBytes
        )
        XCTAssertEqual(observation.observedAt, observedAt)
        XCTAssertEqual(observation.source, .systemVolume)
    }

    func testObservationAgeDoesNotBorrowTheDeepScanTimestamp() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = Observation(
            value: LiveFreeSpace(freeBytes: 10, totalBytes: 100),
            observedAt: observedAt,
            source: .systemVolume
        )

        XCTAssertEqual(observation.ageText(at: observedAt), "방금")
        XCTAssertEqual(
            observation.ageText(at: observedAt.addingTimeInterval(42)),
            "42초 전"
        )
        XCTAssertEqual(
            observation.ageText(at: observedAt.addingTimeInterval(120)),
            "2분 전"
        )
    }

    func testFailedRefreshKeepsLastGoodFreeSpaceObservation() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let failedAt = observedAt.addingTimeInterval(5)
        let observation = Observation(
            value: LiveFreeSpace(freeBytes: 70, totalBytes: 100),
            observedAt: observedAt,
            source: .systemVolume
        )
        var state = LiveState.unobserved

        state.recordFreeSpaceAttempt(observation, attemptedAt: observedAt)
        XCTAssertEqual(state.freeSpace, observation)
        XCTAssertEqual(state.freeSpaceStatus, .healthy)

        state.recordFreeSpaceAttempt(nil, attemptedAt: failedAt)
        XCTAssertEqual(state.freeSpace, observation)
        XCTAssertEqual(state.freeSpaceStatus, .failed(failedAt))
    }

    func testSuccessfulRefreshRecoversHealthAfterFailure() {
        let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let recoveredAt = failedAt.addingTimeInterval(5)
        let observation = Observation(
            value: LiveFreeSpace(freeBytes: 60, totalBytes: 100),
            observedAt: recoveredAt,
            source: .systemVolume
        )
        var state = LiveState.unobserved

        state.recordFreeSpaceAttempt(nil, attemptedAt: failedAt)
        state.recordFreeSpaceAttempt(observation, attemptedAt: recoveredAt)

        XCTAssertEqual(state.freeSpace, observation)
        XCTAssertEqual(state.freeSpaceStatus, .healthy)
    }

    func testStoragePressureUsesExactFiveAndTwentyGBBoundaries() {
        XCTAssertEqual(
            StoragePressure.classify(freeBytes: 5 * gibibyte - 1),
            .danger
        )
        XCTAssertEqual(
            StoragePressure.classify(freeBytes: 5 * gibibyte),
            .warning
        )
        XCTAssertEqual(
            StoragePressure.classify(freeBytes: 20 * gibibyte - 1),
            .warning
        )
        XCTAssertEqual(
            StoragePressure.classify(freeBytes: 20 * gibibyte),
            .normal
        )
    }

    func testLiveStatePressureComesFromLatestSuccessfulObservation() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var state = LiveState.unobserved

        XCTAssertNil(state.storagePressure)

        state.recordFreeSpaceAttempt(
            Observation(
                value: LiveFreeSpace(
                    freeBytes: 4 * gibibyte,
                    totalBytes: 100 * gibibyte
                ),
                observedAt: observedAt,
                source: .systemVolume
            ),
            attemptedAt: observedAt
        )

        XCTAssertEqual(state.storagePressure, .danger)
    }
    func testOSAvailableCapacityNeverChangesRawFreePressureOrRecoveryBaseline() {
        let value = LiveFreeSpace(freeBytes: 4 * gibibyte, totalBytes: 100 * gibibyte,
                                  importantAvailableBytes: 40 * gibibyte,
                                  opportunisticAvailableBytes: 10 * gibibyte)
        XCTAssertEqual(value.pressure, .danger)
        XCTAssertEqual(value.freeGB, 4)
        XCTAssertEqual(value.importantAvailableBytes, 40 * gibibyte)
        XCTAssertEqual(value.opportunisticAvailableBytes, 10 * gibibyte)
        let missing = LiveFreeSpace(freeBytes: 4, totalBytes: 100,
                                    importantAvailableBytes: -1, opportunisticAvailableBytes: 200)
        XCTAssertNil(missing.importantAvailableBytes)
        XCTAssertEqual(missing.opportunisticAvailableBytes, 100)
    }

    func testLegacyCapacityDecodesWithoutOSEstimates() throws {
        let value = try JSONDecoder().decode(LiveFreeSpace.self,
            from: Data(#"{"freeBytes":10,"totalBytes":100}"#.utf8))
        XCTAssertEqual(value.freeBytes, 10)
        XCTAssertNil(value.importantAvailableBytes)
        XCTAssertNil(value.opportunisticAvailableBytes)
    }

    func testCurrentCapacityRequiresRecentSuccessfulObservation() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = Observation(value: LiveFreeSpace(freeBytes: 10, totalBytes: 100), observedAt: date, source: ObservationSource.systemVolume)
        var state = LiveState.unobserved
        state.recordFreeSpaceAttempt(observation, attemptedAt: date)
        XCTAssertNotNil(state.currentFreeSpace(at: date.addingTimeInterval(30)))
        XCTAssertNil(state.currentFreeSpace(at: date.addingTimeInterval(31)))
        XCTAssertNil(state.currentFreeSpace(at: date.addingTimeInterval(-1)))
        state.recordFreeSpaceAttempt(nil, attemptedAt: date.addingTimeInterval(1))
        XCTAssertNil(state.currentFreeSpace(at: date.addingTimeInterval(2)))
        XCTAssertEqual(state.freeSpace, observation)
    }

    func testStoredScannerRiskUsesTheSameBytePolicyAsLiveReadings() throws {
        func snapshot(freeGB: Double, exactBytes: Int64? = nil, measured: Bool = true) throws -> StorageSnapshot {
            var volume: [String: Any] = ["freeGB": freeGB, "totalGB": 500, "usedGB": 470,
                "usePercent": 99, "risk": "danger", "measured": measured]
            if let exactBytes { volume["freeBytes"] = exactBytes }
            return try XCTUnwrap(StorageSnapshot(json: ["volume": volume]))
        }
        XCTAssertEqual(try snapshot(freeGB: 30).risk, "safe")
        XCTAssertEqual(try snapshot(freeGB: 19).risk, "warning")
        XCTAssertEqual(try snapshot(freeGB: 20, exactBytes: 20 * gibibyte - 1).risk, "warning")
        XCTAssertEqual(try snapshot(freeGB: 5).risk, "warning")
        XCTAssertEqual(try snapshot(freeGB: 0, measured: false).risk, "unknown")
        XCTAssertEqual(try snapshot(freeGB: .nan).risk, "unknown")
    }

    func testMalformedLegacyCapacityIsUnknownRatherThanMeasuredZero() throws {
        let malformed: [Any] = [NSNull(), "", "invalid", "NaN", true, false, -1, Double.infinity]
        for value in malformed {
            for key in ["freeGB", "totalGB"] {
                var volume: [String: Any] = ["freeGB": 20, "totalGB": 100, "measured": true]
                volume[key] = value
                let result = try XCTUnwrap(StorageSnapshot(json: ["volume": volume]))
                XCTAssertFalse(result.volumeMeasured, "\(key): \(value)")
                XCTAssertEqual(result.risk, "unknown")
            }
        }
        let missing = try XCTUnwrap(StorageSnapshot(json: ["volume": ["totalGB": 100]]))
        XCTAssertFalse(missing.volumeMeasured)
        let impossible = try XCTUnwrap(StorageSnapshot(json: ["volume": ["freeGB": 101, "totalGB": 100]]))
        XCTAssertFalse(impossible.volumeMeasured)
        let realZero = try XCTUnwrap(StorageSnapshot(json: ["volume": ["freeGB": "0", "totalGB": "100"]]))
        XCTAssertTrue(realZero.volumeMeasured)
        XCTAssertEqual(realZero.risk, "danger")
    }

    func testExactCapacityBoundsTakePriorityAndOnlyRoundedTotalsGetTolerance() throws {
        func read(_ volume: [String: Any]) throws -> StorageSnapshot {
            try XCTUnwrap(StorageSnapshot(json: ["volume": volume]))
        }
        let total = 100 * gibibyte
        XCTAssertTrue(try read(["freeBytes": total, "totalBytes": total]).volumeMeasured)
        XCTAssertFalse(try read(["freeBytes": total + 1, "totalBytes": total]).volumeMeasured)
        XCTAssertFalse(try read(["freeBytes": -1, "freeGB": 20, "totalGB": 100]).volumeMeasured)
        XCTAssertFalse(try read(["freeBytes": NSNull(), "freeGB": 20, "totalGB": 100]).volumeMeasured)
        XCTAssertFalse(try read(["freeBytes": true, "totalBytes": total]).volumeMeasured)
        XCTAssertFalse(try read(["freeBytes": 1.5, "totalBytes": total]).volumeMeasured)
        XCTAssertFalse(try read(["freeBytes": 10, "totalBytes": "bad", "totalGB": 100]).volumeMeasured)
        XCTAssertFalse(try read(["freeBytes": 0, "totalBytes": 0]).volumeMeasured)
        let withinRounding = Int64(100.04 * Double(gibibyte))
        XCTAssertTrue(try read(["freeBytes": withinRounding, "totalGB": 100]).volumeMeasured)
        XCTAssertFalse(try read(["freeBytes": withinRounding, "totalBytes": total, "totalGB": 100]).volumeMeasured)
        XCTAssertFalse(try read(["freeBytes": Int64(100.06 * Double(gibibyte)), "totalGB": 100]).volumeMeasured)
        XCTAssertFalse(try read(["freeGB": 100.04, "totalGB": 100]).volumeMeasured)
    }

}
