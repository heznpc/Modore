import AppKit
import Darwin
import Foundation
@preconcurrency import UserNotifications

struct CPUProcessCounter: Sendable {
    let pid: Int32
    let started: UInt64
    let name: String
    let nanoseconds: UInt64
    var residentBytes: UInt64 = 0
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
        let capacity = max(128, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        var counters: [CPUProcessCounter] = []
        for pid in pids.prefix(max(0, min(Int(count), capacity))) where pid > 0 {
            if let counter = NativeCPUReader.read(pid) { counters.append(counter) }
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

struct CPUSamplingCadence {
    // Detailed live view gets fast updates. Background observation should not
    // keep the machine busy; expensive samples receive additional recovery time.
    static func delay(visible: Bool, thermalPressure: Int, collectionSeconds: Double) -> Double {
        let base = thermalPressure >= 2 ? 20.0 : (visible ? 2.0 : 10.0)
        let measured = collectionSeconds.isFinite ? max(0, collectionSeconds) : 0
        return min(20, max(base, measured * 99))
    }
}

@MainActor
final class CPUWatchService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled: Bool
    @Published private(set) var detail = L10n.text("CPU 감시 꺼짐")
    @Published private(set) var configuring = false
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var previous: CPUSample?
    @Published private(set) var snapshot: HealthSnapshot?
    @Published private(set) var journal = HealthJournal()
    @Published private(set) var journalError: String?
    @Published var showHealth = false
    @Published private(set) var notificationStatus = L10n.text("알림 권한 확인 중")
    private var cpuHighSince: TimeInterval?
    private var canPersist = true
    private var lastSaved = Date.distantPast
    private var noticePolicy = HealthNoticePolicy()
    private let journalURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Modore/health-context.json")

    func markAction(_ label: String) {
        journal.markAction(label, snapshot: snapshot)
        persist()
    }

    private func persist() {
        guard canPersist else { return }
        do {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(journal)
            try data.write(to: journalURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            lastSaved = Date()
            journalError = nil
        } catch { journalError = L10n.format("상황 기록 저장 실패: %@", String(describing: error.localizedDescription)) }
    }

    @discardableResult
    func refreshNotificationStatus() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let allowed = settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
        notificationStatus = allowed ? L10n.text("macOS 알림 허용됨") : L10n.text("알림 차단됨 · 시스템 설정에서 Modore 알림 허용 필요")
        return allowed
    }

    override init() {
        enabled = UserDefaults.standard.object(forKey: "cpuWatchEnabled") as? Bool ?? true
        super.init()
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                let data = try Data(contentsOf: journalURL)
                guard data.count < 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
                journal = try JSONDecoder().decode(HealthJournal.self, from: data)
                journal.resume()
            } catch { canPersist = false; journalError = L10n.format("이전 상황 기록을 읽지 못했습니다: %@", String(describing: error.localizedDescription)) }
        }
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        PressureNotification.register(on: UNUserNotificationCenter.current())
        Task { await refreshNotificationStatus() }
        guard enabled, task == nil else { return }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: L10n.text("사용자가 켠 Mac 상태 감시"))
        }
        detail = L10n.text("CPU 사용량을 관찰하는 중입니다.")
        task = Task { [weak self] in
            while !Task.isCancelled {
                if AppDiagnosticService.shared.active {
                    if self?.previous != nil {
                        self?.previous = nil
                        self?.cpuHighSince = nil
                        self?.journal.resume()
                        self?.persist()
                    }
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    continue
                }
                let started = ProcessInfo.processInfo.systemUptime
                let sample = await Task.detached(priority: .utility) { await CPUSample.captureWithSystemProcesses() }.value
                guard !Task.isCancelled else { return }
                await self?.receive(sample)
                let delay = CPUSamplingCadence.delay(
                    visible: self?.showHealth == true && NSApp.isActive,
                    thermalPressure: sample.thermalPressure,
                    collectionSeconds: ProcessInfo.processInfo.systemUptime - started)
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
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
                if !granted { notificationStatus = L10n.text("알림 차단됨 · 상태 관찰은 계속합니다.") }
            } catch {
                notificationStatus = L10n.format("알림 권한을 확인하지 못했습니다: %@", String(describing: error.localizedDescription))
            }
        }
        enabled = value
        UserDefaults.standard.set(value, forKey: "cpuWatchEnabled")
        task?.cancel(); task = nil; previous = nil; cpuHighSince = nil
        journal.resume(); persist()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        if value { start() } else {
            detail = L10n.text("CPU 감시 꺼짐")
            NSApplication.shared.dockTile.badgeLabel = nil
        }
    }

    func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Modore CPU 알림 테스트")
        content.body = L10n.text("알림이 정상 동작합니다. 실제 CPU 과부하를 의미하는 알림은 아닙니다.")
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "modore-cpu-test", content: content, trigger: nil))
        } catch { detail = L10n.format("테스트 알림 전송 실패: %@", String(describing: error.localizedDescription)) }
    }

    private func receive(_ sample: CPUSample) async {
        let prior = previous
        previous = sample
        let usage = prior.map { sample.usage(since: $0) } ?? []
        let high = usage.reduce(0) { $0 + $1.percent } / Double(max(1, sample.cores)) >= 70
            || (usage.first?.percent ?? 0) >= 150
            || (sample.thermalPressure >= 1 && (usage.first?.percent ?? 0) >= 20)
        if prior.map({ sample.uptime - $0.uptime > 30 }) ?? false { cpuHighSince = nil; journal.resume() }
        if !high { cpuHighSince = nil }
        else if cpuHighSince == nil { cpuHighSince = sample.uptime }
        let sustained = cpuHighSince.map { sample.uptime - $0 >= 60 } ?? false
        let current = await Task.detached(priority: .utility) {
            HealthSnapshot.capture(sample: sample, usage: usage, cpuElevated: sustained, cpuBurst: high)
        }.value
        guard !Task.isCancelled else { return }
        snapshot = current
        let lowStorage = HealthNoticePolicy.storageLevel(current.freeBytes) > 0
        let badge = lowStorage ? current.freeBytes.map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } : nil
        if NSApplication.shared.dockTile.badgeLabel != badge {
            NSApplication.shared.dockTile.badgeLabel = badge
        }
        let changed = journal.observe(current)
        detail = current.summary
        if changed || Date().timeIntervalSince(lastSaved) >= 60 { persist() }
        let managedStorage = AutomaticCachePolicy.ownsStorageNotice(
            enabled: AutomaticCacheConsentStore.isAuthorized(),
            appRunning: true, free: current.freeBytes)
        // Automatic recovery owns storage results. Continue distinct RAM/CPU notices.
        guard !managedStorage || (current.memoryPressure ?? 0) >= 2
            || current.cpuElevated || current.cpuBurst == true else { return }
        let notifyStorage = lowStorage && !managedStorage
        guard enabled, noticePolicy.shouldSend(
            current, journalChanged: changed,
            userPresent: lowStorage || LocalUserPresence.allowsNotification, now: Date()
        ) else { return }
        guard await refreshNotificationStatus() else {
            noticePolicy.didAttempt(current, accepted: false, now: Date())
            return
        }
        let content = UNMutableNotificationContent()
        content.title = current.issues.isEmpty ? L10n.text("부하가 낮아졌습니다") : (
            notifyStorage
                ? L10n.format("공간 부족 · %@ 남음", String(describing: HealthSnapshot.bytes(current.freeBytes)))
                : ((current.memoryPressure ?? 0) >= 2 ? L10n.text("RAM 사용을 줄여야 합니다") : (current.cpuElevated ? L10n.text("CPU 부하가 계속 높습니다") : L10n.text("CPU 순간 부하 감지"))))
        let topProcess = usage.first.map { "\(String($0.name.prefix(22))) CPU \(Int($0.percent))%" }
        let memory = (current.memoryPressure ?? 0) >= 2 ? L10n.text("RAM 주의") : nil
        content.body = notifyStorage
            ? [current.summary, current.cpuElevated || current.cpuBurst == true ? topProcess : nil,
               L10n.text("공간 확보 또는 실행 중인 앱 확인을 여세요.")].compactMap { $0 }.joined(separator: "\n")
            : [topProcess, memory].compactMap { $0 }.joined(separator: " · ")
        content.userInfo = ["modoreRoute": notifyStorage ? "storage" : "health"]
        if notifyStorage { content.categoryIdentifier = PressureNotification.category }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: notifyStorage ? PressureNotification.category : "modore-health", content: content, trigger: nil))
            noticePolicy.didAttempt(current, accepted: true, now: Date())
            await refreshNotificationStatus()
        } catch {
            notificationStatus = L10n.format("상황 감지됨 · 알림 전송 실패: %@", String(describing: error.localizedDescription))
            noticePolicy.didAttempt(current, accepted: false, now: Date())
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        if let destination = PressureNotification.destination(
            action: response.actionIdentifier,
            route: response.notification.request.content.userInfo["modoreRoute"] as? String
        ) {
            Task { @MainActor [weak self] in
                if destination.absoluteString == "modore://health" { self?.showHealth = true }
                NSWorkspace.shared.open(destination)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
