import Foundation

/// Notification delivery is independent of the incident journal. A journal
/// records a condition even when the screen is locked or a delivery fails.
/// Only an accepted notification consumes the pending change.
struct HealthNoticePolicy {
    private(set) var pending = false
    private(set) var lastDeliveredAt: Date?
    private var lastAttemptAt: Date?
    private var deliveredStorageLevel = 0
    private var deliveredMemoryLevel = 0
    private var deliveredCPULevel = 0

    private static func memoryLevel(_ snapshot: HealthSnapshot) -> Int {
        let pressure = snapshot.memoryPressure ?? 0
        return pressure >= 4 ? 2 : (pressure >= 2 ? 1 : 0)
    }

    private static func cpuLevel(_ snapshot: HealthSnapshot) -> Int {
        guard snapshot.cpuElevated else { return 0 }
        return snapshot.thermalPressure >= 1 ? 2 : 1
    }

    static func storageLevel(_ freeBytes: Int64?) -> Int {
        guard let freeBytes else { return 0 }
        let gib: Int64 = 1_073_741_824
        if freeBytes < 3 * gib { return 4 }
        if freeBytes < 5 * gib { return 3 }
        if freeBytes < 10 * gib { return 2 }
        if freeBytes < 20 * gib { return 1 }
        return 0
    }

    static func reminderInterval(_ freeBytes: Int64?) -> TimeInterval {
        switch storageLevel(freeBytes) {
        case 4: return 300
        case 3: return 600
        case 2: return 1_800
        default: return 7_200
        }
    }

    mutating func shouldSend(
        _ snapshot: HealthSnapshot, journalChanged: Bool,
        userPresent: Bool, now: Date
    ) -> Bool {
        if let free = snapshot.freeBytes, free >= 21 * 1_073_741_824 {
            deliveredStorageLevel = 0
        }
        let memory = Self.memoryLevel(snapshot)
        let cpu = Self.cpuLevel(snapshot)
        if let pressure = snapshot.memoryPressure, pressure < 2 { deliveredMemoryLevel = 0 }
        if snapshot.cpuAvailable && !snapshot.cpuElevated { deliveredCPULevel = 0 }
        pending = pending || journalChanged
            || Self.storageLevel(snapshot.freeBytes) > deliveredStorageLevel
            || memory > deliveredMemoryLevel || cpu > deliveredCPULevel
        // The journal retains all issue labels from an incident. Recurrent
        // RAM/CPU pressure must not disappear behind those historical labels.
        var reminder: TimeInterval?
        if Self.storageLevel(snapshot.freeBytes) > 0 {
            reminder = Self.reminderInterval(snapshot.freeBytes)
        }
        if memory > 0 || cpu > 0 {
            reminder = min(reminder ?? .infinity, memory == 2 ? 300 : 600)
        }
        if let reminder,
           let delivered = lastDeliveredAt,
           now.timeIntervalSince(delivered) >= reminder {
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
        if snapshot.memoryPressure != nil { deliveredMemoryLevel = Self.memoryLevel(snapshot) }
        if snapshot.cpuAvailable { deliveredCPULevel = Self.cpuLevel(snapshot) }
        pending = false
    }
}
