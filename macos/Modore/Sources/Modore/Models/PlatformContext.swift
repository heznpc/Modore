import Foundation

struct PowerSnapshot: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case external, battery, ups, unknown }
    let observedAt: Date
    let source: Source
    /// nil means the source list was unavailable, false means no internal battery.
    let hasBattery: Bool?
    let batteryPercent: Int?
    let isCharging: Bool?
    let lowPowerMode: Bool

    static func percentage(current: Int?, maximum: Int?) -> Int? {
        guard let current, let maximum, maximum > 0, current >= 0, current <= maximum else { return nil }
        return Int((Double(current) / Double(maximum) * 100).rounded())
    }
}

/// A path becoming available does not measure internet reachability, bandwidth,
/// packet loss, application traffic, or latency.
struct ConnectivitySnapshot: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case available, unavailable, connectionRequired }
    enum Interface: String, Codable, Sendable { case wifi, ethernet, cellular, loopback, other }
    let observedAt: Date
    let status: Status
    let interfaces: [Interface]
    let isExpensive: Bool
    let isConstrained: Bool
}

struct CPUCoverage: Codable, Equatable, Sendable {
    let measuredProcesses: Int
    let unavailableProcesses: Int
    /// nil if process enumeration failed; zero coverage is not proof of idleness.
    let enumeratedProcesses: Int?
    var isPartial: Bool { enumeratedProcesses == nil || unavailableProcesses > 0 }
}
