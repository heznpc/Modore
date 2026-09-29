import Foundation
import Darwin

struct Phase: Codable, Equatable {
    let id: String
    let title: String
    let instruction: String
    let seconds: Int
    static let standard: [Phase] = [
        .init(id: "first-input", title: "처음 입력하기", instruction: "", seconds: 0),
        .init(id: "typing", title: "계속 입력하기", instruction: "", seconds: 0),
        .init(id: "sidebar", title: "채팅 목록으로 이동", instruction: "", seconds: 0),
        .init(id: "attachment", title: "사진 첨부하기", instruction: "", seconds: 0)
    ]
}

// A real recording belongs to the user. Only the explicit diagnostic harness
// may finish automatically; an idle user is not evidence of a completed action.
enum RecordingPolicy {
    static func shouldFinish(elapsed: Double, smoke: Bool) -> Bool { smoke && elapsed >= 12 }
}

struct CPUCounter {
    let birth: UInt64
    let totalTicks: UInt64
    let timestamp: Double
    // proc_pid_rusage CPU times are Mach absolute ticks on this platform.
    static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()
    static var continuousSeconds: Double { Double(mach_continuous_time()) * nanosecondsPerTick / 1_000_000_000 }
    static var nanosecondsPerTick: Double { Double(timebase.numer) / Double(timebase.denom) }

    static func percent(previous: CPUCounter?, current: CPUCounter,
                        nanosecondsPerTick: Double = CPUCounter.nanosecondsPerTick) -> Double? {
        guard let previous, previous.birth == current.birth,
              current.timestamp.isFinite, previous.timestamp.isFinite,
              current.timestamp > previous.timestamp, current.timestamp - previous.timestamp <= 10,
              current.totalTicks >= previous.totalTicks else { return nil }
        return Double(current.totalTicks - previous.totalTicks) * nanosecondsPerTick
            / ((current.timestamp - previous.timestamp) * 1_000_000_000) * 100
    }
}

// A frame is one capture instant. Sum concurrent PIDs before averaging frames;
// idle siblings must not dilute a busy renderer's CPU usage.
struct CPUAggregates {
    private(set) var values: [String: [Double]] = [:]
    private(set) var durations: [String: [Double]] = [:]
    func mean(_ key: String) -> Double? {
        guard let values = values[key], let durations = durations[key] else { return nil }
        let span = durations.reduce(0, +)
        return span > 0 ? zip(values, durations).reduce(0) { $0 + $1.0 * $1.1 } / span : nil
    }
    mutating func append(phase: String, samples: [(role: String, percent: Double)], interval: Double = 1) {
        guard interval.isFinite, interval > 0, interval <= 10 else { return }
        var frame: [String: Double] = [:]
        for sample in samples { frame[sample.role, default: 0] += sample.percent }
        for (role, percent) in frame {
            values[phase + "|" + role, default: []].append(percent)
            durations[phase + "|" + role, default: []].append(interval)
        }
    }
}
