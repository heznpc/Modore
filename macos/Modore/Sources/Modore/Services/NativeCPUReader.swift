import Darwin
import Foundation

/// One CPU timebase and PID identity implementation for live health and replay diagnostics.
enum NativeCPUReader {
    static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()
    static var continuousSeconds: Double { Double(mach_continuous_time()) * nanosecondsPerTick / 1_000_000_000 }
    static var nanosecondsPerTick: Double { Double(timebase.numer) / Double(timebase.denom) }

    static func read(_ pid: Int32) -> CPUProcessCounter? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutableBytes(of: &usage) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard result == 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let label = proc_pidpath(pid, &path, UInt32(path.count)) > 0
            ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : String(cString: name)
        return CPUProcessCounter(pid: pid, started: usage.ri_proc_start_abstime,
            name: label,
            nanoseconds: UInt64(Double(usage.ri_user_time &+ usage.ri_system_time) * nanosecondsPerTick),
            residentBytes: usage.ri_resident_size)
    }

    static func percent(before: CPUProcessCounter?, after: CPUProcessCounter, elapsed: Double) -> Double? {
        guard let before, before.pid == after.pid, before.started == after.started,
              elapsed > 0, elapsed <= 10, after.nanoseconds >= before.nanoseconds else { return nil }
        return Double(after.nanoseconds - before.nanoseconds) / elapsed / 10_000_000
    }
}
