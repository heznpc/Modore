import Foundation

/// Notification delivery is independent of the incident journal. A journal
/// records a condition even when the screen is locked or a delivery fails.
/// Only an accepted notification consumes the pending change.
struct HealthNoticePolicy {
    private(set) var pending = false
    private(set) var lastDeliveredAt: Date?
    private var lastAttemptAt: Date?
    private var deliveredStorageLevel = 0

    static func storageLevel(_ freeBytes: Int64?) -> Int {
        guard let freeBytes else { return 0 }
        let gib: Int64 = 1_073_741_824
        if freeBytes < 5 * gib { return 3 }
        if freeBytes < 10 * gib { return 2 }
        if freeBytes < 20 * gib { return 1 }
        return 0
    }

    mutating func shouldSend(
        _ snapshot: HealthSnapshot, journalChanged: Bool,
        userPresent: Bool, now: Date
    ) -> Bool {
        if let free = snapshot.freeBytes, free >= 21 * 1_073_741_824 {
            deliveredStorageLevel = 0
        }
        pending = pending || journalChanged
            || Self.storageLevel(snapshot.freeBytes) > deliveredStorageLevel
        // Persistent low space still needs a reminder, even when another
        // issue keeps the same journal incident open for several days.
        if Self.storageLevel(snapshot.freeBytes) > 0,
           let delivered = lastDeliveredAt, now.timeIntervalSince(delivered) >= 21_600 {
            pending = true
        }
        if snapshot.issues.isEmpty, lastDeliveredAt == nil { pending = false }
        guard pending, userPresent else { return false }
        return lastAttemptAt.map { now.timeIntervalSince($0) >= 60 } ?? true
    }

    mutating func didAttempt(_ snapshot: HealthSnapshot, accepted: Bool, now: Date) {
        lastAttemptAt = now
        guard accepted else { return }
        lastDeliveredAt = now
        if snapshot.freeBytes != nil {
            deliveredStorageLevel = Self.storageLevel(snapshot.freeBytes)
        }
        pending = false
    }
}
