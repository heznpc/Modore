import Foundation

/// One process's actual CPU usage during the observation window, from
/// idle_cpu.sh's two-sample delta (not ps's lifetime-decayed average).
struct ObservedProcessRow: Identifiable {
    let id = UUID()
    let percent: Double
    let pid: Int
    let name: String
    let ownerPid: Int
    let ownerName: String
    let startedFromShell: Bool

    /// Same meaning as ScanModels' BackgroundCpuRow: work not attributable to
    /// the process's own owner, so quitting the named app wouldn't stop it.
    var isDetachedFromAnApp: Bool { startedFromShell && ownerPid != pid }
}

/// One connection or listening port that appeared during the observation
/// window and wasn't present at its start, from network_watch.sh.
struct ObservedConnectionRow: Identifiable {
    let id = UUID()
    let kind: String
    let process: String
    let pid: Int
    let address: String

    var isListening: Bool { kind == "listen" }
}

struct ObservationResult {
    let windowSeconds: Int
    let processRows: [ObservedProcessRow]
    let newConnectionRows: [ObservedConnectionRow]
    let networkUnavailable: Bool
}
