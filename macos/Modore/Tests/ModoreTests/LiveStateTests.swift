import Foundation
import XCTest
@testable import Modore

final class LiveStateTests: XCTestCase {
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
}
