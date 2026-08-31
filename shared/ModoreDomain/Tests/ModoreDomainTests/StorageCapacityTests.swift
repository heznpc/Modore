import Foundation
import XCTest
@testable import ModoreDomain

final class StorageCapacityTests: XCTestCase {
    private let gibibyte = StorageRecoveryPolicy.bytesPerGiB

    func testSnapshotDerivesUsedBytesAndDefaultPressure() {
        let snapshot = StorageCapacitySnapshot(
            totalBytes: 100 * gibibyte,
            availableBytes: 4 * gibibyte,
            measuredAt: Date(timeIntervalSince1970: 1_800_000_000),
            confidence: .measured
        )

        XCTAssertEqual(snapshot.usedBytes, 96 * gibibyte)
        XCTAssertEqual(snapshot.pressure, .danger)
        XCTAssertEqual(snapshot.requiredGainBytes(), 16 * gibibyte)
    }

    func testSnapshotNormalizesImpossibleCapacityInputs() {
        let negative = StorageCapacitySnapshot(
            totalBytes: -1,
            availableBytes: -2,
            measuredAt: .distantPast,
            confidence: .estimated
        )
        XCTAssertEqual(negative.totalBytes, 0)
        XCTAssertEqual(negative.availableBytes, 0)
        XCTAssertEqual(negative.usedBytes, 0)

        let excessiveAvailable = StorageCapacitySnapshot(
            totalBytes: 10,
            availableBytes: 20,
            measuredAt: .distantPast,
            confidence: .estimated
        )
        XCTAssertEqual(excessiveAvailable.availableBytes, 10)
        XCTAssertEqual(excessiveAvailable.usedBytes, 0)
    }

    func testDefaultPressureUsesExactFiveAndTwentyGiBBoundaries() {
        XCTAssertEqual(StoragePressure.classify(availableBytes: 5 * gibibyte - 1), .danger)
        XCTAssertEqual(StoragePressure.classify(availableBytes: 5 * gibibyte), .warning)
        XCTAssertEqual(StoragePressure.classify(availableBytes: 20 * gibibyte - 1), .warning)
        XCTAssertEqual(StoragePressure.classify(availableBytes: 20 * gibibyte), .normal)
    }

    func testRequiredGainUsesByteArithmeticAndNeverGoesNegative() {
        let policy = StorageRecoveryPolicy.default

        XCTAssertEqual(policy.requiredGainBytes(currentAvailableBytes: -1), 20 * gibibyte)
        XCTAssertEqual(policy.requiredGainBytes(currentAvailableBytes: 2 * gibibyte), 18 * gibibyte)
        XCTAssertEqual(policy.requiredGainBytes(currentAvailableBytes: 20 * gibibyte), 0)
        XCTAssertEqual(policy.requiredGainBytes(currentAvailableBytes: 40 * gibibyte), 0)
    }

    func testCustomPolicyControlsPressureAndRecoveryGoal() {
        let policy = StorageRecoveryPolicy(
            targetAvailableBytes: 30,
            warningThresholdBytes: 12,
            dangerThresholdBytes: 3
        )
        let snapshot = StorageCapacitySnapshot(
            totalBytes: 100,
            availableBytes: 10,
            measuredAt: .distantPast,
            confidence: .stale
        )

        XCTAssertEqual(snapshot.pressure(using: policy), .warning)
        XCTAssertEqual(snapshot.requiredGainBytes(using: policy), 20)
    }

    func testPolicyNormalizesThresholdOrdering() {
        let policy = StorageRecoveryPolicy(
            targetAvailableBytes: 1,
            warningThresholdBytes: 2,
            dangerThresholdBytes: 3
        )

        XCTAssertEqual(policy.dangerThresholdBytes, 3)
        XCTAssertEqual(policy.warningThresholdBytes, 3)
        XCTAssertEqual(policy.targetAvailableBytes, 3)
    }

    func testSnapshotCodableRoundTripPreservesMeasurementEvidence() throws {
        let snapshot = StorageCapacitySnapshot(
            totalBytes: 128 * gibibyte,
            availableBytes: 17 * gibibyte,
            measuredAt: Date(timeIntervalSince1970: 1_800_000_000),
            confidence: .estimated
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(StorageCapacitySnapshot.self, from: encoded)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.usedBytes, 111 * gibibyte)
        XCTAssertEqual(decoded.pressure, .warning)
        XCTAssertEqual(snapshot.capturedAt, snapshot.measuredAt)
        XCTAssertEqual(snapshot.reliability, .estimated)
    }

    func testSnapshotDecodeNormalizesUntrustedCapacityValues() throws {
        let data = Data(#"{"totalBytes":10,"availableBytes":20,"measuredAt":0,"confidence":"measured"}"#.utf8)
        let snapshot = try JSONDecoder().decode(StorageCapacitySnapshot.self, from: data)

        XCTAssertEqual(snapshot.totalBytes, 10)
        XCTAssertEqual(snapshot.availableBytes, 10)
        XCTAssertEqual(snapshot.usedBytes, 0)
    }

    func testPolicyAndPressureAreCodable() throws {
        let policy = StorageRecoveryPolicy(
            targetAvailableBytes: 30,
            warningThresholdBytes: 20,
            dangerThresholdBytes: 5
        )

        let encodedPolicy = try JSONEncoder().encode(policy)
        XCTAssertEqual(
            try JSONDecoder().decode(StorageRecoveryPolicy.self, from: encodedPolicy),
            policy
        )

        let encodedPressure = try JSONEncoder().encode(StoragePressure.danger)
        XCTAssertEqual(
            try JSONDecoder().decode(StoragePressure.self, from: encodedPressure),
            .danger
        )
    }

    func testPolicyDecodePreservesThresholdOrderingInvariant() throws {
        let data = Data(#"{"targetAvailableBytes":1,"warningThresholdBytes":2,"dangerThresholdBytes":3}"#.utf8)
        let policy = try JSONDecoder().decode(StorageRecoveryPolicy.self, from: data)

        XCTAssertEqual(policy.dangerThresholdBytes, 3)
        XCTAssertEqual(policy.warningThresholdBytes, 3)
        XCTAssertEqual(policy.targetAvailableBytes, 3)
    }

    func testExistingMacGigabyteCompatibilityHelper() {
        XCTAssertEqual(
            StorageRecoveryPolicy.requiredGainGB(currentFreeGB: 2.6),
            17.4,
            accuracy: 0.000_001
        )
        XCTAssertEqual(StorageRecoveryPolicy.requiredGainGB(currentFreeGB: 20), 0)
        XCTAssertEqual(StorageRecoveryPolicy.requiredGainGB(currentFreeGB: 40), 0)
    }
}
