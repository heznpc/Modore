import AppKit
import Darwin
import Foundation
@preconcurrency import UserNotifications

struct CPUProcessCounter: Sendable {
    let pid: Int32
    let started: UInt64
    let name: String
    let nanoseconds: UInt64
}

struct CPUProcessUsage: Equatable, Sendable {
    let pid: Int32
    let name: String
    let percent: Double
}

struct CPUSample: Sendable {
    let uptime: TimeInterval
    let counters: [CPUProcessCounter]
    let thermalPressure: Int
    let cores: Int
    var systemProcesses: [CPUProcessUsage] = []

    static func capture() -> CPUSample {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanosecondsPerTick = Double(timebase.numer) / Double(timebase.denom)
        let capacity = max(128, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        var counters: [CPUProcessCounter] = []
        for pid in pids.prefix(max(0, min(Int(count), capacity))) where pid > 0 {
            var usage = rusage_info_v2()
            let status = withUnsafeMutableBytes(of: &usage) { bytes in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, bytes.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
            }
            guard status == 0 else { continue }
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let label = proc_pidpath(pid, &path, UInt32(path.count)) > 0
                ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : String(cString: name)
            counters.append(CPUProcessCounter(pid: pid, started: usage.ri_proc_start_abstime,
                                             name: label,
                                             nanoseconds: UInt64(Double(usage.ri_user_time &+ usage.ri_system_time) * nanosecondsPerTick)))
        }
        // Continuous time includes sleep, unlike ProcessInfo.systemUptime.
        let continuousSeconds = Double(mach_continuous_time()) * Double(timebase.numer)
            / Double(timebase.denom) / 1_000_000_000
        return CPUSample(uptime: continuousSeconds, counters: counters,
                         thermalPressure: ProcessInfo.processInfo.thermalState.rawValue,
                         cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    static func captureWithSystemProcesses() async -> CPUSample {
        var sample = capture()
        // WindowServer and other protected processes reject libproc queries.
        // The OS-provided ps reader exposes those statistics without requesting
        // administrator access; never invoke a shell or inspect command arguments.
        let result = await LocalProcessRunner.capture(
            executable: "/bin/ps", arguments: ["-axo", "pid=,pcpu=,comm="],
            currentDirectory: URL(fileURLWithPath: "/"), timeout: 2, maxOutputBytes: 1_000_000)
        if result.succeeded { sample.systemProcesses = parseSystemProcesses(result.output) }
        return sample
    }

    static func parseSystemProcesses(_ text: String) -> [CPUProcessUsage] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int32(fields[0]), pid > 0,
                  let percent = Double(fields[1]), percent.isFinite, percent >= 0 else { return nil }
            return CPUProcessUsage(pid: pid, name: URL(fileURLWithPath: String(fields[2])).lastPathComponent,
                                   percent: percent)
        }
    }

    func usage(since previous: CPUSample) -> [CPUProcessUsage] {
        let elapsed = uptime - previous.uptime
        // Wake from sleep and PID reuse must not masquerade as sustained load.
        guard elapsed > 0, elapsed <= 30 else { return [] }
        let old = Dictionary(previous.counters.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let native: [CPUProcessUsage] = counters.compactMap { counter in
            guard let before = old[counter.pid], before.started == counter.started,
                  counter.nanoseconds >= before.nanoseconds else { return nil }
            return CPUProcessUsage(pid: counter.pid, name: counter.name,
                                   percent: Double(counter.nanoseconds - before.nanoseconds) / elapsed / 10_000_000)
        }
        let measured = Set(native.map(\.pid))
        return (native + systemProcesses.filter { !measured.contains($0.pid) }).sorted { $0.percent > $1.percent }
    }
}

struct CPUAlertPolicy {
    private var elevatedSince: TimeInterval?
    private var lastNotice: TimeInterval?

    mutating func evaluate(usage: [CPUProcessUsage], sample: CPUSample) -> Bool {
        let total = usage.reduce(0) { $0 + $1.percent } / Double(max(1, sample.cores))
        let highest = usage.first?.percent ?? 0
        let elevated = total >= 70 || highest >= 150 || (sample.thermalPressure >= 1 && highest >= 20)
        guard elevated else { elevatedSince = nil; return false }
        if elevatedSince == nil { elevatedSince = sample.uptime }
        guard sample.uptime - (elevatedSince ?? sample.uptime) >= 60,
              lastNotice.map({ sample.uptime - $0 >= 600 }) ?? true else { return false }
        lastNotice = sample.uptime
        return true
    }
}

@MainActor
final class CPUWatchService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled: Bool
    @Published private(set) var detail = "CPU 감시 꺼짐"
    @Published private(set) var configuring = false
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var previous: CPUSample?
    private var policy = CPUAlertPolicy()

    override init() {
        enabled = UserDefaults.standard.bool(forKey: "cpuWatchEnabled")
        super.init()
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        guard enabled, task == nil else { return }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "사용자가 켠 CPU 부하 알림 감시")
        }
        detail = "CPU 사용량을 관찰하는 중입니다."
        task = Task { [weak self] in
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) { await CPUSample.captureWithSystemProcesses() }.value
                guard !Task.isCancelled else { return }
                await self?.receive(sample)
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { return }
            }
        }
    }

    func setEnabled(_ value: Bool) async {
        guard !configuring else { return }
        configuring = true
        defer { configuring = false }
        if value {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                guard granted else {
                    detail = "macOS에서 Modore 알림이 차단돼 있습니다. 시스템 설정 → 알림에서 허용해주세요."
                    return
                }
            } catch {
                detail = "알림 권한을 확인하지 못했습니다: \(error.localizedDescription)"
                return
            }
        }
        enabled = value
        UserDefaults.standard.set(value, forKey: "cpuWatchEnabled")
        task?.cancel(); task = nil; previous = nil; policy = CPUAlertPolicy()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        if value { start() } else { detail = "CPU 감시 꺼짐" }
    }

    func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Modore CPU 알림 테스트"
        content.body = "알림이 정상 동작합니다. 실제 CPU 과부하를 의미하는 알림은 아닙니다."
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "modore-cpu-test", content: content, trigger: nil))
        } catch { detail = "테스트 알림 전송 실패: \(error.localizedDescription)" }
    }

    private func receive(_ sample: CPUSample) async {
        let prior = previous
        previous = sample
        guard let prior else { return }
        let usage = sample.usage(since: prior)
        let top = Array(usage.prefix(3))
        guard !top.isEmpty else {
            _ = policy.evaluate(usage: [], sample: sample)
            detail = "CPU 관찰값을 다시 확인하는 중입니다."
            return
        }
        detail = top.map { "\($0.name) \(Int($0.percent))%" }.joined(separator: " · ")
        guard policy.evaluate(usage: usage, sample: sample) else { return }
        let content = UNMutableNotificationContent()
        content.title = sample.thermalPressure >= 1 ? "발열 부담이 1분 이상 지속됩니다" : "CPU 부하가 1분 이상 높습니다"
        content.body = top.map { "\($0.name) (PID \($0.pid)) \(Int($0.percent))%" }.joined(separator: "\n")
            + "\n10초 간격 관찰 · CPU 100%는 코어 1개 사용량"
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "modore-cpu-load", content: content, trigger: nil))
        } catch { detail = "CPU 부하 감지 · 알림 전송 실패: \(error.localizedDescription)" }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
