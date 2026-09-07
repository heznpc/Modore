import XCTest
@testable import Modore

final class RecoveryAccountingTests: XCTestCase {
    func testAdditionalGoalDoesNotBecomeTheRecommendedTwentyGiB() {
        let plan = CleanupRecoveryPlan(baselineFreeBytes: 10 * StorageBytes.perGiB,
                                       requestedGainBytes: StorageBytes.perGiB, entries: [])
        XCTAssertEqual(plan.requestedGainBytes, StorageBytes.perGiB)
        XCTAssertEqual(plan.desiredFreeBytes, 11 * StorageBytes.perGiB)
    }

    func testOverflowingGoalCannotExecute() {
        let plan = CleanupRecoveryPlan(baselineFreeBytes: Int64.max,
                                       requestedGainBytes: 1, entries: [])
        XCTAssertNil(plan.desiredFreeBytes)
        XCTAssertFalse(plan.canExecute)
    }

    func testResultPreservesDecreaseZeroIncreaseAndUnknown() {
        for final: Int64? in [9, 10, 11, nil] {
            let result = CleanupRecoveryResult(
                baselineFreeBytes: 10, finalFreeBytes: final, desiredFreeBytes: 11,
                plannedCount: 1, items: [], stoppedAfterFailure: false, rescanScheduled: false
            )
            XCTAssertEqual(result.actualChangeBytes, final.map { $0 - 10 })
            XCTAssertEqual(result.goalMet, final == 11)
            XCTAssertEqual(result.freeSpaceMeasured, final != nil)
        }
    }

    func testByteConversionsRejectNonfiniteNegativeAndOverflow() {
        XCTAssertNil(StorageBytes.fromLegacyGiB(.nan))
        XCTAssertNil(StorageBytes.fromLegacyGiB(.infinity))
        XCTAssertNil(StorageBytes.fromLegacyGiB(-1))
        XCTAssertNil(StorageBytes.fromLegacyGiB(.greatestFiniteMagnitude))
        XCTAssertNil(StorageBytes.fromKiB(Int64.max))
        XCTAssertEqual(StorageBytes.fromKiB(-1), -1024)
        XCTAssertEqual(StorageBytes.fromLegacyGiB(1), StorageBytes.perGiB)
    }

    func testFormattingUsesBinaryUnitsAndExplicitUnknown() {
        XCTAssertEqual(StorageBytes.text(StorageBytes.perGiB), "1.0 GiB")
        XCTAssertEqual(StorageBytes.changeText(-StorageBytes.perGiB), "-1.0 GiB")
        XCTAssertEqual(StorageBytes.changeText(1024), "+1.0 KiB")
        XCTAssertEqual(StorageBytes.changeText(0), "0 B")
        XCTAssertEqual(StorageBytes.changeText(nil), "미확인")
        XCTAssertFalse(StorageBytes.text(Int64.min).isEmpty)
    }

    func testByteProtocolPreservesSignedValuesAndDoesNotFallbackForMissingMeasurements() throws {
        for raw in ["-1024", "0", "1024", "", "invalid", "9223372036854775808"] {
            let result = try XCTUnwrap(CleanupPreview(protocolText: """
            version\t1
            operation\texecute
            status\tcomplete
            recipeId\tnpm_cache
            accountingVersion\t2
            physicalDeltaKB\t777
            physicalDeltaBytes\t\(raw)
            reclaimedKB\t888
            reclaimedBytes\t
            """))
            XCTAssertEqual(result.physicalDeltaBytes, Int64(raw))
            XCTAssertNil(result.reclaimedBytes)
        }
    }

    func testLegacyKiBProtocolStaysReadableWithoutInventingAZeroMeasurement() throws {
        for (raw, expected): (String, Int64?) in [("-2", -2048), ("2", 2048), ("0", nil), ("00", nil), ("+2", nil), ("", nil)] {
            let result = try XCTUnwrap(CleanupPreview(protocolText: """
            version\t1
            operation\texecute
            status\tcomplete
            recipeId\tnpm_cache
            physicalDeltaKB\t\(raw)
            """))
            XCTAssertEqual(result.physicalDeltaBytes, expected)
        }
    }

    func testReceiptJSONRejectsUnknownAccountingVersionsAndKeepsMeasuredZero() throws {
        for version in [0, 1, 2, 99] {
            let data = Data("""
            {"kind":"modore_cleanup_receipt","at":"","recipeId":"npm_cache","label":"fixture","status":"complete",
             "accountingVersion":\(version),"estimatedKB":777,"reclaimedKB":777,"physicalDeltaKB":777,
             "estimatedBytes":1024,"reclaimedBytes":1024,"physicalDeltaBytes":0}
            """.utf8)
            let receipt = try JSONDecoder().decode(ScreeCleanupReceipt.self, from: data)
            XCTAssertEqual(receipt.targetEstimateBytes, [1, 2].contains(version) ? 1024 : nil)
            XCTAssertEqual(receipt.targetReductionBytes, [1, 2].contains(version) ? 1024 : nil)
            XCTAssertEqual(receipt.volumeChangeBytes, [1, 2].contains(version) ? 0 : nil)
        }
    }
}
