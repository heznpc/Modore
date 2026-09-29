import Foundation
import Darwin

final class Recorder {
    let folder: URL
    private let queue = DispatchQueue(label: "heznpc.lagqa.recorder", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var phase = "prepare"
    private var targets: [Int32: String] = [:]
    private var previous: [Int32: CPUCounter] = [:]
    private var samplers: [Process] = []
    private var csv: FileHandle?
    private var events: [[String: Any]] = []
    private var rows = 0
    private var errors: [String] = []
    private var ticks = 0
    private var lastCapture: Double?
    private var targetBirths: [Int32: UInt64] = [:]
    private var mainBirth: UInt64?
    private var missingRows = 0
    private var logCursors: [URL: (identity: UInt64, offset: UInt64, partial: Data)] = [:]
    private var logEvents: [[String: String]] = []
    private var aggregates = CPUAggregates()
    private var ended = false
    private let mainPID: Int32
    private let startedAt = Date()
    private let clock = CPUCounter.continuousSeconds
    private let smoke: Bool
    private let iso = ISO8601DateFormatter()

    init(mainPID: Int32, smoke: Bool) throws {
        self.mainPID = mainPID
        self.smoke = smoke
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Heznpc/LagQA/Runs")
        folder = base.appendingPathComponent((smoke ? "smoke-" : "run-") + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("native-private"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = folder.appendingPathComponent("cpu.csv")
        FileManager.default.createFile(atPath: path.path, contents: Data("time,phase,pid,role,cpu_percent,rss_bytes,status,elapsed_seconds,interval_seconds\n".utf8),
            attributes: [.posixPermissions: 0o600])
        csv = try FileHandle(forWritingTo: path)
        try csv?.seekToEnd()
    }

    func start() {
        queue.async {
            self.mainBirth = self.usage(self.mainPID)?.ri_proc_start_abstime
            self.discoverTargets()
            self.readLogAppends(initial: true)
            self.events.append(["time": self.iso.string(from: self.startedAt), "seconds": CPUCounter.continuousSeconds - self.clock, "event": "start", "smokeTest": self.smoke])
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { self.capture() }
            self.timer = timer
            timer.resume()
        }
    }

    func changePhase(_ phase: Phase) {
        queue.async {
            guard !self.ended else { return }
            self.phase = phase.id
            self.previous.removeAll(); self.lastCapture = nil
            self.events.append(["time": self.iso.string(from: Date()), "seconds": CPUCounter.continuousSeconds - self.clock, "event": "phase", "id": phase.id,
                                "instruction": phase.instruction, "plannedSeconds": phase.seconds])
            for process in self.samplers where !process.isRunning && process.terminationStatus != 0 {
                self.errors.append("native sample exited with status \(process.terminationStatus); see native-private diagnostics")
            }
            self.samplers.removeAll { !$0.isRunning }
            guard phase.id != "prepare", phase.id != "settle" else { return }
            let renderer = self.targets.filter { $0.value == "renderer" }
                .max { self.resident($0.key) < self.resident($1.key) }?.key
            for pid in [self.mainPID, renderer].compactMap({ $0 }) {
                guard self.samplers.count < 4 else {
                    self.errors.append("native sample skipped: previous sample still finalizing")
                    continue
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                let output = self.folder.appendingPathComponent("native-private/\(phase.id)-\(pid).sample.txt")
                process.arguments = [String(pid), String(max(1, phase.seconds - 4)), "20", "-file", output.path]
                process.standardOutput = FileHandle.nullDevice
                let diagnostics = output.appendingPathExtension("stderr.txt")
                FileManager.default.createFile(atPath: diagnostics.path, contents: nil, attributes: [.posixPermissions: 0o600])
                process.standardError = try? FileHandle(forWritingTo: diagnostics)
                do { try process.run(); self.samplers.append(process) }
                catch { self.errors.append("native sample launch failed (pid \(pid))") }
            }
        }
    }

    private func resident(_ pid: Int32) -> UInt64 { usage(pid)?.ri_resident_size ?? 0 }
    private func usage(_ pid: Int32) -> rusage_info_v2? {
        var value = rusage_info_v2()
        let result = withUnsafeMutableBytes(of: &value) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        return result == 0 ? value : nil
    }

    private func discoverTargets() {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            var next: [Int32: String] = [:]
            guard let mainBirth, usage(mainPID)?.ri_proc_start_abstime == mainBirth else {
                targets = [:]; previous = [:]
                errors.append("target exited or restarted; no replacement PID is measured")
                return
            }
            var processRows: [(pid: Int32, parent: Int32, name: String)] = []
            for line in text.split(separator: "\n") {
                let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { continue }
                let path = String(parts[2])
                let name = URL(fileURLWithPath: path).lastPathComponent
                guard name != "<defunct>" else { continue }
                processRows.append((pid, parent, name))
                if pid == mainPID { next[pid] = "ChatGPT-main" }
                else if name == "WindowServer" { next[pid] = "WindowServer" }
                else if name == "Modore" || name == "QuotaPie" || name == "bun" { next[pid] = name }
                else if pid == getpid() { next[pid] = "LagQA-observer" }
                else if parent == getpid() { next[pid] = "LagQA-" + name }
            }
            var descendants: Set<Int32> = [mainPID]
            for _ in 0..<16 {
                let expanded = descendants.union(processRows.filter { descendants.contains($0.parent) }.map(\.pid))
                if expanded == descendants { break }
                descendants = expanded
            }
            for row in processRows where descendants.contains(row.pid) && row.pid != mainPID {
                next[row.pid] = row.name.contains("Renderer") ? "renderer" : "target-work:" + row.name
            }
            if next.count > 64 { errors.append("process coverage truncated to 64") }
            let selected = [mainPID] + next.keys.filter { $0 != mainPID }.sorted().prefix(63)
            targets = Dictionary(uniqueKeysWithValues: selected.compactMap { pid in next[pid].map { (pid, $0) } })
            targetBirths = Dictionary(uniqueKeysWithValues: selected.compactMap { pid in usage(pid).map { (pid, $0.ri_proc_start_abstime) } })
            previous = previous.filter { targets[$0.key] != nil }
        } catch { errors.append("process discovery failed") }
    }

    private func capture() {
        guard !ended else { return }
        ticks += 1
        if ticks % 5 == 0 { discoverTargets() }
        let now = Date(), monotonic = CPUCounter.continuousSeconds
        let interval = lastCapture.map { monotonic - $0 } ?? 0
        lastCapture = monotonic
        var frame: [(role: String, percent: Double)] = []
        for (pid, role) in targets.sorted(by: { $0.key < $1.key }) {
            var cpu = "", rss = "", status = "unavailable"
            if let value = usage(pid), value.ri_proc_start_abstime == targetBirths[pid] {
                let counter = CPUCounter(birth: value.ri_proc_start_abstime,
                    totalTicks: value.ri_user_time &+ value.ri_system_time, timestamp: monotonic)
                if let percent = CPUCounter.percent(previous: previous[pid], current: counter) {
                    cpu = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), percent)
                    frame.append((role, percent))
                    status = "ok"
                } else { status = interval == 0 ? "baseline" : "discontinuity" }
                previous[pid] = counter
                rss = String(value.ri_resident_size)
            }
            if status == "unavailable" { previous.removeValue(forKey: pid) }
            if status == "unavailable" || status == "discontinuity" { missingRows += 1 }
            let safeRole = role.replacingOccurrences(of: ",", with: "_")
            let line = "\(iso.string(from: now)),\(phase),\(pid),\(safeRole),\(cpu),\(rss),\(status),\(monotonic - clock),\(interval)\n"
            do { try csv?.write(contentsOf: Data(line.utf8)); rows += 1 }
            catch { if !errors.contains("CPU recording failed") { errors.append("CPU recording failed") } }
        }
        aggregates.append(phase: phase, samples: frame, interval: interval)
        readLogAppends(initial: false)
    }

    // Only newly appended fixed diagnostic markers are retained, never raw logs,
    // conversation content, file paths, auth tokens or keyboard input.
    private func readLogAppends(initial: Bool) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.openai.codex/" + formatter.string(from: Date()))
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let markers = ["ResizeObserver loop completed with undelivered notifications.", "local_thread_hover_card",
                       "Starting git repo watcher", "render-process-gone", "renderer-process-crashed"]
        for file in files where file.pathExtension == "log" {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let identity = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            if initial { logCursors[file] = (identity, size, Data()); continue }
            var cursor = logCursors[file] ?? (identity, 0, Data())
            if cursor.identity != identity || size < cursor.offset { cursor = (identity, 0, Data()) }
            guard size > cursor.offset, let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            if size - cursor.offset > 1_048_576 {
                cursor.offset = size - 1_048_576; cursor.partial = Data()
                errors.append("log backlog exceeded 1 MiB; some markers may be missing")
            }
            do {
                try handle.seek(toOffset: cursor.offset)
                let data = try handle.read(upToCount: Int(min(1_048_576, size - cursor.offset))) ?? Data()
                cursor.offset += UInt64(data.count)
                cursor.partial.append(data)
                while let end = cursor.partial.firstIndex(of: 10) {
                    let line = String(decoding: cursor.partial[..<end], as: UTF8.self)
                    cursor.partial.removeSubrange(...end)
                    for marker in markers where line.contains(marker) {
                        logEvents.append(["observedAt": iso.string(from: Date()), "phase": phase, "marker": marker,
                                          "logTime": String(line.prefix(24))])
                    }
                }
                if cursor.partial.count > 65_536 { cursor.partial = Data() }
                logCursors[file] = cursor
            } catch { errors.append("log marker read failed") }
        }
    }

    func finish(cancelled: Bool, completion: @escaping (String) -> Void) {
        queue.async {
            guard !self.ended else { return }
            self.capture()
            self.ended = true
            self.timer?.cancel(); self.timer = nil
            if !cancelled {
                let group = DispatchGroup()
                for process in self.samplers where process.isRunning {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); group.leave() }
                }
                if group.wait(timeout: .now() + 8) == .timedOut {
                    self.errors.append("native sample finalization exceeded 8 seconds; partial results retained")
                }
            }
            self.samplers.filter(\.isRunning).forEach { $0.terminate() }
            try? self.csv?.close(); self.csv = nil
            self.events.append(["time": self.iso.string(from: Date()), "seconds": CPUCounter.continuousSeconds - self.clock, "event": cancelled ? "cancelled" : "finished"])
            let samples = ((try? FileManager.default.contentsOfDirectory(at: self.folder.appendingPathComponent("native-private"), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(".sample.txt") }
            if samples.isEmpty { self.errors.append("no native samples saved; CPU and timeline are available") }
            var summary = "# ChatGPT 전환 동작 진단\n\n"
            summary += self.smoke ? "자동 실행 점검 결과입니다. 사용자 동작을 재현한 측정이 아닙니다.\n\n" : "사용자가 시작과 종료를 선택한 자유 측정입니다. 관찰 구간은 실제 조작 종류나 시각을 의미하지 않습니다.\n\n"
            summary += "- 시작: \(self.iso.string(from: self.startedAt))\n- 결과: \(cancelled ? "중단됨" : "수집 종료")\n- CPU 레코드: \(self.rows)\n- 진단 로그 표식: \(self.logEvents.count)\n\n"
            summary += "| 구간 / 프로세스 | CPU 평균 % | CPU 최대 % | 표본 수 |\n|---|---:|---:|---:|\n"
            for (key, values) in self.aggregates.values.sorted(by: { $0.key < $1.key }) {
                summary += String(format: "| %@ | %.2f | %.2f | %d |\n", key.replacingOccurrences(of: "|", with: " / "),
                                  self.aggregates.mean(key) ?? 0, values.max() ?? 0, values.count)
            }
            summary += "\nCPU는 프로세스 누적 실행시간 차이로 계산한 약 1초 평균입니다. 100%는 논리 코어 하나입니다. Mach 시간 단위를 나노초로 변환합니다. 같은 역할의 여러 PID는 같은 수집 시점별로 합산한 뒤 경과 시간으로 가중 평균·최댓값을 계산합니다. 구간 전환 경계와 10초 초과 관측 공백은 평균에서 제외합니다. 접근 불가·PID 교체·관측 공백은 cpu.csv에 unavailable/discontinuity로 기록하며 0으로 대체하지 않습니다. 누락 CPU 행 \(self.missingRows)개. 누락이 있으면 역할 합계는 실제 부하보다 작을 수 있습니다.\n\n"
            summary += "## 해석 한계\n\n키 입력·화면 프레임·첨부 내용은 수집하지 않습니다. 이 자료만으로 입력 지연 밀리초나 원인을 확정할 수 없습니다. 호출 스택은 관찰 구간별 native-private 폴더에 저장되며 불완전한 심볼과 로컬 경로를 포함할 수 있습니다. 공개 공유에는 이 요약과 markers.json을 우선 사용하세요. LagQA 및 sample 프로세스 자체도 관찰 부하를 만듭니다.\n"
            if !self.errors.isEmpty { summary += "\n## 수집 제한\n" + Set(self.errors).sorted().map { "- " + $0 }.joined(separator: "\n") + "\n" }
            do {
                try self.writeJSON(self.events, "timeline.json")
                try self.writeJSON(self.logEvents, "markers.json")
                let app = Bundle(url: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
                try self.writeJSON(["os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "appVersion": app?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    "appBuild": app?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    "smokeTest": self.smoke, "cancelled": cancelled, "cpuRows": self.rows, "nativeSamples": samples.count,
                    "cpuCalculationVersion": 3,
                    "missingCPURows": self.missingRows,
                    "machTimebaseNumer": CPUCounter.timebase.numer,
                    "machTimebaseDenom": CPUCounter.timebase.denom,
                    "cpuAggregation": "sum concurrent PIDs by role, then elapsed-time weighted mean/max over capture frames",
                    "errors": self.errors], "manifest.json")
                try summary.write(to: self.folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
                let limits = self.errors.isEmpty ? "" : " · 수집 제한 \(Set(self.errors).count)종"
                DispatchQueue.main.async { completion("CPU \(self.rows)건 · 로그 \(self.logEvents.count)건 · 스택 \(samples.count)개\(limits)") }
            } catch { DispatchQueue.main.async { completion("저장 오류: \(error.localizedDescription)") } }
        }
    }

    private func writeJSON(_ object: Any, _ name: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}
