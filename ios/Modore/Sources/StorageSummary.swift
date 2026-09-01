import Foundation
import ModoreDomain

struct DeviceStorageCapacityValues: Equatable, Sendable {
    let totalBytes: Int?
    let importantAvailableBytes: Int64?
    let legacyAvailableBytes: Int?
}

protocol DeviceStorageReading {
    func capacityValues(
        at url: URL,
        forKeys keys: Set<URLResourceKey>
    ) throws -> DeviceStorageCapacityValues
}

struct FoundationDeviceStorageReader: DeviceStorageReading {
    func capacityValues(
        at url: URL,
        forKeys keys: Set<URLResourceKey>
    ) throws -> DeviceStorageCapacityValues {
        let values = try url.resourceValues(forKeys: keys)
        return DeviceStorageCapacityValues(
            totalBytes: values.volumeTotalCapacity,
            importantAvailableBytes: values.volumeAvailableCapacityForImportantUsage,
            legacyAvailableBytes: values.volumeAvailableCapacity
        )
    }
}

struct DeviceStorageSnapshot: Equatable, Sendable {
    static let targetBytes: Int64 = StorageRecoveryPolicy.defaultTargetAvailableBytes
    static let capacityResourceKeys: Set<URLResourceKey> = [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
    ]

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

    static func current(
        reader: any DeviceStorageReading = FoundationDeviceStorageReader(),
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> DeviceStorageSnapshot? {
        let values: DeviceStorageCapacityValues
        do {
            values = try reader.capacityValues(
                at: homeDirectory,
                forKeys: capacityResourceKeys
            )
        } catch {
            return nil
        }

        guard let total = values.totalBytes, total >= 0 else { return nil }
        let available: Int64
        if let important = values.importantAvailableBytes {
            available = important
        } else if let legacy = values.legacyAvailableBytes {
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
