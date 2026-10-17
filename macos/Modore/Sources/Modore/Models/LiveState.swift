import Foundation
import ModoreDomain

enum ObservationSource: String, Equatable, Sendable {
    case systemVolume
}

struct Observation<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let observedAt: Date
    let source: ObservationSource

    func isFresh(at now: Date = Date(), maximumAge: TimeInterval = 30) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= maximumAge
    }

    func ageText(at date: Date = Date()) -> String {
        let rawAge = date.timeIntervalSince(observedAt)
        guard rawAge >= -60 else { return L10n.text("관찰 시각 확인 필요") }
        let age = max(0, rawAge)
        if age < 10 { return L10n.text("방금") }
        if age < 60 { return L10n.format("%@초 전", String(describing: Int(age))) }
        return L10n.format("%@분 전", String(describing: Int(age / 60)))
    }
}

struct LiveFreeSpace: Codable, Equatable, Sendable {
    /// Immediately unallocated bytes; the common pressure/recovery baseline.
    let freeBytes: Int64
    let totalBytes: Int64
    /// macOS estimates may include purgeable space. They are not free bytes or
    /// a promise that Modore's cleanup candidates can recover this capacity.
    let importantAvailableBytes: Int64?
    let opportunisticAvailableBytes: Int64?

    init(freeBytes: Int64, totalBytes: Int64,
         importantAvailableBytes: Int64? = nil, opportunisticAvailableBytes: Int64? = nil) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        func capacity(_ value: Int64?) -> Int64? {
            guard let value, value >= 0, totalBytes > 0 else { return nil }
            return min(value, totalBytes)
        }
        self.importantAvailableBytes = capacity(importantAvailableBytes)
        self.opportunisticAvailableBytes = capacity(opportunisticAvailableBytes)
    }

    var freeGB: Double { Double(freeBytes) / 1_073_741_824 }
    var totalGB: Double { Double(totalBytes) / 1_073_741_824 }
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return (1 - Double(freeBytes) / Double(totalBytes)) * 100
    }

    var pressure: StoragePressure {
        StoragePressure.classify(freeBytes: freeBytes)
    }
}

enum ObservationStatus: Equatable, Sendable {
    case observing
    case healthy
    case failed(Date)
}

struct LiveState: Equatable, Sendable {
    var freeSpace: Observation<LiveFreeSpace>?
    var freeSpaceStatus: ObservationStatus

    static let unobserved = LiveState(
        freeSpace: nil,
        freeSpaceStatus: .observing
    )

    var storagePressure: StoragePressure? {
        freeSpace?.value.pressure
    }

    /// Preserve the last good observation for history, but never present a
    /// failed or expired reading as a current status.
    func currentFreeSpace(at now: Date = Date()) -> Observation<LiveFreeSpace>? {
        guard freeSpaceStatus == .healthy, let freeSpace, freeSpace.isFresh(at: now) else { return nil }
        return freeSpace
    }

    mutating func recordFreeSpaceAttempt(
        _ observation: Observation<LiveFreeSpace>?,
        attemptedAt: Date
    ) {
        if let observation {
            freeSpace = observation
            freeSpaceStatus = .healthy
        } else {
            freeSpaceStatus = .failed(attemptedAt)
        }
    }
}
