import Foundation
import Darwin

/// A single serial owner. No shell, Python, polling subprocesses or overlapping captures.
actor AppDiagnosticRecorder {
    let folder: URL
    private let target: DiagnosticTarget
    private let condition: String
    private let started = Date()
    private let clock = NativeCPUReader.continuousSeconds
    private var lastTime: Double?
    private var previous: [Int32: CPUProcessCounter] = [:]
    private var members: Set<Int32> = []
    private var frames: [DiagnosticFrame] = []
    private var events: [DiagnosticEvent] = []
    private var lastDiscovery = -10.0
    private var discoveryTruncated = false
    private var sampleProcess: Process?
    private var sampleCount = 0
    private var lastStack = -30.0
    private var hottest: Int32?
    private var file: FileHandle?
    private var eventFile: FileHandle?
    private var finished = false
    private var writeFailed = false

    init(target: DiagnosticTarget, condition: String, root: URL? = nil) throws {
        self.target = target; self.condition = String(condition.prefix(120))
        let root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Modore/AppDiagnostics")
        folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("frames.jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forWritingTo: url)
        let eventURL = folder.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: eventURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        eventFile = try FileHandle(forWritingTo: eventURL)
        let metadata = try JSONEncoder().encode(target)
        try metadata.write(to: folder.appendingPathComponent("target.json"), options: .atomic)
    }

    func mark(_ kind: String, _ detail: String) {
        guard !finished, events.count < DiagnosticBudget.events else { return }
        let event = DiagnosticEvent(seconds: NativeCPUReader.continuousSeconds - clock, kind: kind, detail: detail)
        events.append(event)
        do { try eventFile?.write(contentsOf: JSONEncoder().encode(event) + Data([10])) }
        catch { writeFailed = true }
    }

    private func discover() {
        let capacity = min(32768, max(128, Int(proc_listallpids(nil, 0)) + 128))
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var parents: [Int32: Int32] = [:]
        for pid in pids.prefix(max(0, min(Int(count), capacity))) where pid > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 {
                parents[pid] = Int32(info.pbi_ppid)
            }
        }
        var found: Set<Int32> = [target.pid]
        for _ in 0..<16 {
            let next = Set(parents.filter { found.contains($0.value) }.map(\.key)).union(found)
            if next == found { break }
            found = next
        }
        discoveryTruncated = found.count > DiagnosticBudget.processes
        members = Set(found.subtracting([target.pid]).sorted().prefix(DiagnosticBudget.processes - 1))
        members.insert(target.pid)
    }

    func capture() -> (DiagnosticFrame?, String?) {
        guard !finished else { return (nil, "수집 종료") }
        if writeFailed { return (nil, "기록 저장 실패") }
        let begin = NativeCPUReader.continuousSeconds
        guard let main = NativeCPUReader.read(target.pid), main.started == target.birth else { return (nil, "대상 앱 종료 또는 재시작") }
        let seconds = begin - clock
        guard seconds < DiagnosticBudget.duration, frames.count < DiagnosticBudget.frames else { return (nil, "5분 수집 한도 도달") }
        if begin - clock - lastDiscovery >= 4 { discover(); lastDiscovery = seconds }
        let elapsed = lastTime.map { begin - $0 } ?? 0
        var next: [Int32: CPUProcessCounter] = [:]
        var usages: [(Int32, Double)] = []
        var rss: UInt64 = 0, unavailable = discoveryTruncated ? 1 : 0
        for pid in members {
            guard let counter = NativeCPUReader.read(pid) else { unavailable += 1; continue }
            next[pid] = counter; rss &+= counter.residentBytes
            if let value = NativeCPUReader.percent(before: previous[pid], after: counter, elapsed: elapsed) {
                usages.append((pid, value))
            } else if lastTime != nil { unavailable += 1 }
        }
        func overhead(_ pid: Int32?) -> Double? {
            guard let pid, let counter = NativeCPUReader.read(pid) else { return nil }
            next[pid] = counter
            return NativeCPUReader.percent(before: previous[pid], after: counter, elapsed: elapsed)
        }
        let observer = overhead(getpid())
        let sampler = overhead(sampleProcess?.isRunning == true ? sampleProcess?.processIdentifier : nil)
        hottest = usages.max { $0.1 < $1.1 }?.0
        previous = next; lastTime = begin
        var frame = DiagnosticFrame(seconds: seconds, interval: elapsed,
            targetCPU: usages.isEmpty ? nil : usages.reduce(0) { $0 + $1.1 }, observerCPU: observer,
            samplerCPU: sampler, residentBytes: rss, available: usages.count, unavailable: unavailable,
            collectionMilliseconds: (NativeCPUReader.continuousSeconds - begin) * 1000,
            thermal: ProcessInfo.processInfo.thermalState.rawValue)
        let rendererValues = usages.filter { next[$0.0]?.name.contains("Renderer") == true }
        if !rendererValues.isEmpty { frame.rendererCPU = rendererValues.reduce(0) { $0 + $1.1 } }
        frame.topProcesses = usages.sorted { $0.1 > $1.1 }.prefix(8).map {
            DiagnosticProcess(pid: $0.0, name: String((next[$0.0]?.name ?? "unknown").prefix(80)), cpu: $0.1)
        }
        frames.append(frame)
        do { try file?.write(contentsOf: JSONEncoder().encode(frame) + Data([10])) }
        catch { writeFailed = true; return (frame, "기록 저장 실패") }
        return (frame, nil)
    }

    func collectStack() -> String {
        guard !finished, sampleCount < DiagnosticBudget.stacks else { return "스택 수집 한도에 도달했습니다." }
        guard sampleProcess?.isRunning != true, NativeCPUReader.continuousSeconds - clock - lastStack >= 30 else { return "스택 수집은 30초 간격으로 가능합니다." }
        guard let main = NativeCPUReader.read(target.pid), main.started == target.birth,
              let pid = hottest, let known = previous[pid], NativeCPUReader.read(pid)?.started == known.started else { return "대상 프로세스를 확인할 수 없습니다." }
        do {
            let directory = folder.appendingPathComponent("native-private")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("stack-\(sampleCount).txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), "3", "20", "-file", path.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            sampleProcess = process; sampleCount += 1; lastStack = NativeCPUReader.continuousSeconds - clock
            mark("stack-start", "사용자 요청 · 3초 native sample")
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self.completeStack(process)
            }
            return "3초 스택 수집을 시작했습니다."
        } catch { mark("stack-failed", "스택 도구 실행 실패"); return "스택 도구를 실행하지 못했습니다." }
    }

    private func completeStack(_ process: Process) {
        if process.isRunning { process.terminate(); mark("stack-partial", "수집 시간 초과 · 부분 결과") }
        else { mark(process.terminationStatus == 0 ? "stack-saved" : "stack-failed", "스택 도구 종료") }
    }

    func finish(_ reason: String) throws -> DiagnosticResult {
        if sampleProcess?.isRunning == true {
            sampleProcess?.terminate(); mark("stack-partial", "검사 종료로 스택 수집 중단")
        }
        finished = true
        try file?.close(); file = nil
        try eventFile?.close(); eventFile = nil
        let result = DiagnosticResult(id: UUID(uuidString: folder.lastPathComponent)!, target: target,
            condition: condition, started: started, frames: frames, events: events,
            finishReason: writeFailed ? "기록 저장 실패 · 부분 결과" : reason,
            timebaseNumer: NativeCPUReader.timebase.numer, timebaseDenom: NativeCPUReader.timebase.denom, schemaVersion: 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: folder.appendingPathComponent("result.json"), options: .atomic)
        try result.report.write(to: folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        return result
    }
}
