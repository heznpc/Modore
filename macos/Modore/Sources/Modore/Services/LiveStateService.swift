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
        let value = LiveFreeSpace(
            freeBytes: free.int64Value,
            totalBytes: total.int64Value
        )
        guard value.freeBytes >= 0, value.totalBytes > 0 else { return nil }
        return Observation(
            value: value,
            observedAt: observedAt,
            source: .systemVolume
        )
    }
}
