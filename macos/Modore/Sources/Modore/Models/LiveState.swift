import Foundation

enum ObservationSource: String, Equatable, Sendable {
    case systemVolume
}

struct Observation<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let observedAt: Date
    let source: ObservationSource

    func ageText(at date: Date = Date()) -> String {
        let rawAge = date.timeIntervalSince(observedAt)
        guard rawAge >= -60 else { return "관찰 시각 확인 필요" }
        let age = max(0, rawAge)
        if age < 10 { return "방금" }
        if age < 60 { return "\(Int(age))초 전" }
        return "\(Int(age / 60))분 전"
    }
}

struct LiveFreeSpace: Equatable, Sendable {
    let freeBytes: Int64
    let totalBytes: Int64

    var freeGB: Double { Double(freeBytes) / 1_073_741_824 }
    var totalGB: Double { Double(totalBytes) / 1_073_741_824 }
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return (1 - Double(freeBytes) / Double(totalBytes)) * 100
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
