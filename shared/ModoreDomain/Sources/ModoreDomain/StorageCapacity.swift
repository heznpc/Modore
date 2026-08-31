import Foundation

/// How much confidence a caller can place in a capacity measurement.
///
/// A snapshot remains useful when it is estimated or stale, but consumers can
/// avoid presenting those values as a fresh, exact recovery result.
public enum StorageMeasurementConfidence: String, Codable, Sendable, Equatable {
    case measured
    case estimated
    case stale
}

/// The domain language used by newer clients. Keep the confidence spelling as
/// a type alias so existing Mac code and persisted values remain compatible.
public typealias StorageMeasurementReliability = StorageMeasurementConfidence

/// Platform-independent storage pressure used by every Modore client.
public enum StoragePressure: String, Codable, Sendable, Equatable {
    case normal
    case warning
    case danger

    public static let dangerThresholdBytes = StorageRecoveryPolicy.defaultDangerThresholdBytes
    public static let warningThresholdBytes = StorageRecoveryPolicy.defaultWarningThresholdBytes

    /// Compatibility spelling for existing clients whose system API reports
    /// the value as `freeBytes`.
    public static func classify(freeBytes: Int64) -> StoragePressure {
        classify(availableBytes: freeBytes)
    }

    public static func classify(
        availableBytes: Int64,
        policy: StorageRecoveryPolicy = .default
    ) -> StoragePressure {
        policy.pressure(availableBytes: availableBytes)
    }

    public var needsRecovery: Bool { self != .normal }
}

/// Shared recovery thresholds. Values are bytes so platform-specific UIs do
/// not need to agree on a floating-point GB representation.
public struct StorageRecoveryPolicy: Codable, Sendable, Equatable {
    public static let bytesPerGiB: Int64 = 1_073_741_824
    public static let defaultTargetAvailableBytes = 20 * bytesPerGiB
    public static let defaultWarningThresholdBytes = 20 * bytesPerGiB
    public static let defaultDangerThresholdBytes = 5 * bytesPerGiB

    /// Compatibility value for the existing Mac goal UI.
    public static let desiredFreeGB = 20.0

    public static let `default` = StorageRecoveryPolicy()

    public let targetAvailableBytes: Int64
    public let warningThresholdBytes: Int64
    public let dangerThresholdBytes: Int64

    private enum CodingKeys: String, CodingKey {
        case targetAvailableBytes
        case warningThresholdBytes
        case dangerThresholdBytes
    }

    public init(
        targetAvailableBytes: Int64 = StorageRecoveryPolicy.defaultTargetAvailableBytes,
        warningThresholdBytes: Int64 = StorageRecoveryPolicy.defaultWarningThresholdBytes,
        dangerThresholdBytes: Int64 = StorageRecoveryPolicy.defaultDangerThresholdBytes
    ) {
        let normalizedDanger = max(0, dangerThresholdBytes)
        let normalizedWarning = max(normalizedDanger, warningThresholdBytes)
        self.dangerThresholdBytes = normalizedDanger
        self.warningThresholdBytes = normalizedWarning
        self.targetAvailableBytes = max(normalizedWarning, targetAvailableBytes)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            targetAvailableBytes: try values.decode(Int64.self, forKey: .targetAvailableBytes),
            warningThresholdBytes: try values.decode(Int64.self, forKey: .warningThresholdBytes),
            dangerThresholdBytes: try values.decode(Int64.self, forKey: .dangerThresholdBytes)
        )
    }

    public func pressure(availableBytes: Int64) -> StoragePressure {
        if availableBytes < dangerThresholdBytes { return .danger }
        if availableBytes < warningThresholdBytes { return .warning }
        return .normal
    }

    public func requiredGainBytes(currentAvailableBytes: Int64) -> Int64 {
        let available = max(0, currentAvailableBytes)
        guard available < targetAvailableBytes else { return 0 }
        return targetAvailableBytes - available
    }

    /// Compatibility helper for the existing Mac goal UI. New clients should
    /// keep capacity arithmetic in bytes and use `requiredGainBytes`.
    public static func requiredGainGB(
        currentFreeGB: Double,
        desiredFreeGB: Double = StorageRecoveryPolicy.desiredFreeGB
    ) -> Double {
        max(0, desiredFreeGB - max(0, currentFreeGB))
    }
}

/// One capacity reading. Total and available values are normalized into a
/// physically valid range at the boundary so derived used bytes cannot become
/// negative or overflow in downstream clients.
public struct StorageCapacitySnapshot: Codable, Sendable, Equatable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let measuredAt: Date
    public let confidence: StorageMeasurementConfidence

    /// Preferred domain spelling for the point at which the value was captured.
    public var capturedAt: Date { measuredAt }

    /// Preferred domain spelling for the trust level of the measurement.
    public var reliability: StorageMeasurementReliability { confidence }

    private enum CodingKeys: String, CodingKey {
        case totalBytes
        case availableBytes
        case measuredAt
        case confidence
    }

    public init(
        totalBytes: Int64,
        availableBytes: Int64,
        measuredAt: Date,
        confidence: StorageMeasurementConfidence
    ) {
        let normalizedTotal = max(0, totalBytes)
        self.totalBytes = normalizedTotal
        self.availableBytes = min(max(0, availableBytes), normalizedTotal)
        self.measuredAt = measuredAt
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            totalBytes: try values.decode(Int64.self, forKey: .totalBytes),
            availableBytes: try values.decode(Int64.self, forKey: .availableBytes),
            measuredAt: try values.decode(Date.self, forKey: .measuredAt),
            confidence: try values.decode(StorageMeasurementConfidence.self, forKey: .confidence)
        )
    }

    public var usedBytes: Int64 { totalBytes - availableBytes }

    public var pressure: StoragePressure {
        pressure(using: .default)
    }

    public func pressure(using policy: StorageRecoveryPolicy) -> StoragePressure {
        policy.pressure(availableBytes: availableBytes)
    }

    public func requiredGainBytes(using policy: StorageRecoveryPolicy = .default) -> Int64 {
        policy.requiredGainBytes(currentAvailableBytes: availableBytes)
    }
}
