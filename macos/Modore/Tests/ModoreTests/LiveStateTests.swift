import Foundation
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
}
