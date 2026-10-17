import Foundation

enum LiveStateService {
    static func observeFreeSpace(
        path: String = "/",
        observedAt: Date = Date()
    ) -> Observation<LiveFreeSpace>? {
        guard let attributes = try? FileManager().attributesOfFileSystem(forPath: path),
              let free = attributes[.systemFreeSize] as? NSNumber,
              let total = attributes[.systemSize] as? NSNumber else {
            return nil
        }
        let capacities = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey
        ])
        let value = LiveFreeSpace(
            freeBytes: free.int64Value,
            totalBytes: total.int64Value,
            importantAvailableBytes: capacities?.volumeAvailableCapacityForImportantUsage,
            opportunisticAvailableBytes: capacities?.volumeAvailableCapacityForOpportunisticUsage
        )
        guard value.freeBytes >= 0, value.totalBytes > 0,
              value.freeBytes <= value.totalBytes else { return nil }
        return Observation(
            value: value,
            observedAt: observedAt,
            source: .systemVolume
        )
    }
}
