import XCTest
@testable import Modore
import ModoreDomain

final class ModoreTests: XCTestCase {
    func testStorageSnapshotCalculatesUsedAndGoalDeficit() {
        let snapshot = DeviceStorageSnapshot(totalBytes: 128_000_000_000, availableBytes: 12_500_000_000)
        XCTAssertEqual(snapshot.usedBytes, 115_500_000_000)
        XCTAssertEqual(snapshot.targetDeficitBytes, StorageRecoveryPolicy.defaultTargetAvailableBytes - 12_500_000_000)
    }

    func testStorageSnapshotDoesNotReportNegativeDeficit() {
        let snapshot = DeviceStorageSnapshot(
            totalBytes: 256_000_000_000,
            availableBytes: StorageRecoveryPolicy.defaultTargetAvailableBytes + 1
        )
        XCTAssertEqual(snapshot.targetDeficitBytes, 0)
    }

    func testByteFormattingUsesReadableDecimalUnits() {
        XCTAssertEqual(StorageFormatting.bytes(0), "0 B")
        XCTAssertEqual(
            StorageFormatting.bytes(1_610_612_736, locale: Locale(identifier: "en_US")),
            "1.5 GiB"
        )
        XCTAssertEqual(
            StorageFormatting.bytes(20 * StorageRecoveryPolicy.bytesPerGiB, locale: Locale(identifier: "en_US")),
            "20 GiB"
        )
    }

    func testDurationFormattingSummarizesHoursMinutesAndSeconds() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(DurationFormatting.string(0, locale: locale), "0s")
        XCTAssertEqual(DurationFormatting.string(65, locale: locale), "1m 5s")
        XCTAssertEqual(DurationFormatting.string(3661, locale: locale), "1h 1m")
    }

    func testMediaSummaryEmptyIsSafeBeforeAuthorization() {
        XCTAssertEqual(MediaSummary.empty.videoCount, 0)
        XCTAssertEqual(MediaSummary.empty.screenRecordingCount, 0)
        XCTAssertEqual(MediaSummary.empty.authorization, .notDetermined)
    }
}
