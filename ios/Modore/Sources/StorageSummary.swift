import Foundation
import ModoreDomain

struct DeviceStorageSnapshot: Equatable, Sendable {
    static let targetBytes: Int64 = StorageRecoveryPolicy.defaultTargetAvailableBytes

    private let capacity: StorageCapacitySnapshot

    init(
        totalBytes: Int64,
        availableBytes: Int64,
        measuredAt: Date = Date(),
        confidence: StorageMeasurementConfidence = .measured
    ) {
        capacity = StorageCapacitySnapshot(
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            measuredAt: measuredAt,
            confidence: confidence
        )
    }

    var totalBytes: Int64 { capacity.totalBytes }
    var availableBytes: Int64 { capacity.availableBytes }

    var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    var targetDeficitBytes: Int64 {
        capacity.requiredGainBytes()
    }

    var pressure: StoragePressure { capacity.pressure }

    static func current(fileManager: FileManager = .default) -> DeviceStorageSnapshot? {
        let values: URLResourceValues
        do {
            values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
                forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            )
        } catch {
            return nil
        }

        guard let total = values.volumeTotalCapacity, total >= 0 else { return nil }
        let available: Int64
        if let important = values.volumeAvailableCapacityForImportantUsage {
            available = important
        } else if let legacy = values.volumeAvailableCapacity {
            available = Int64(legacy)
        } else {
            return nil
        }
        guard available >= 0 else { return nil }
        return DeviceStorageSnapshot(totalBytes: Int64(total), availableBytes: available)
    }
}

enum StorageFormatting {
    static func bytes(_ value: Int64, locale: Locale = .current) -> String {
        let bytes = Double(max(0, value))
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var size = bytes
        var index = 0
        while size >= 1024 && index < units.count - 1 {
            size /= 1024
            index += 1
        }

        if index == 0 { return "\(Int(size)) B" }
        let precision: FloatingPointFormatStyle<Double>.Configuration.Precision =
            size >= 100 || size.rounded() == size
            ? .fractionLength(0)
            : .fractionLength(0...1)
        return "\(size.formatted(.number.locale(locale).precision(precision))) \(units[index])"
    }
}
