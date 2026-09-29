import AppKit
import SwiftUI

@MainActor
final class AppDiagnosticService: ObservableObject {
    static let shared = AppDiagnosticService()
    static let readyStatus = "대상 앱을 확인하고 검사를 시작하세요."
    @Published private(set) var apps: [DiagnosticTarget] = []
    @Published var selectedPID: Int32 = 0
    @Published var condition = "현재 상태"
    @Published var repeats = 1
    @Published private(set) var active = false
    @Published private(set) var saving = false
    @Published private(set) var replaying = false
    @Published private(set) var status = AppDiagnosticService.readyStatus
    @Published private(set) var lastMarker: String?
    @Published private(set) var frame: DiagnosticFrame?
    @Published private(set) var results: [DiagnosticResult] = []
    private(set) var presentations: [UUID: DiagnosticPresentation] = [:]
    @Published var baselineID: UUID?
    @Published private(set) var output: URL?
    let replay = AppDiagnosticReplay()
    private var recorder: AppDiagnosticRecorder?
    private var collectionTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private var panel: NSPanel?
    private weak var resultWindow: NSWindow?
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Modore/AppDiagnostics")
    var selected: DiagnosticTarget? { apps.first { $0.pid == selectedPID } }
    var baseline: DiagnosticResult? { results.first { $0.id == baselineID } }

    func refreshApps() {
        guard !active else { return }
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.compactMap {
            guard let counter = NativeCPUReader.read($0.processIdentifier), let id = $0.bundleIdentifier else { return nil }
            return DiagnosticTarget(pid: $0.processIdentifier, birth: counter.started, name: $0.localizedName ?? "App", bundleID: id,
                version: $0.bundleURL.flatMap(Bundle.init(url:))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        }.sorted { $0.name < $1.name }
        if !apps.contains(where: { $0.pid == selectedPID }) {
            let remembered = UserDefaults.standard.string(forKey: "diagnosticTargetBundleID")
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            selectedPID = apps.first(where: { $0.bundleID == remembered })?.pid
                ?? apps.first(where: { $0.pid == frontmost })?.pid
                ?? apps.first(where: { $0.bundleID == "com.openai.codex" || $0.bundleID == "com.openai.chat" })?.pid
                ?? apps.first?.pid ?? 0
        }
    }
    func loadHistory() async {
        guard !active else { return }
        let root = root
        let saved = await Task.detached(priority: .utility) {
            let directories = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            let results = directories.prefix(20).compactMap { folder -> DiagnosticResult? in
                let url = folder.appendingPathComponent("result.json")
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4_000_000,
                      let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(DiagnosticResult.self, from: data)
            }
            return (results, Dictionary(uniqueKeysWithValues: results.map { ($0.id, DiagnosticPresentation($0)) }))
        }.value
        if !active { presentations = saved.1; results = saved.0.sorted { $0.started > $1.started } }
    }
    func start() {
        guard !active, !saving, let target = selected else { return }
        do {
            resultWindow = NSApp.keyWindow
            let recorder = try AppDiagnosticRecorder(target: target, condition: condition)
            self.recorder = recorder; active = true; output = nil; frame = nil; lastMarker = nil
            UserDefaults.standard.set(target.bundleID, forKey: "diagnosticTargetBundleID")
            status = "기록 중 · 평소처럼 사용하고 증상이 나타나면 표식을 남기세요. 고부하 증거는 자동 보존합니다."
            collectionTask = Task { [weak self] in
                while !Task.isCancelled {
                    let (frame, reason) = await recorder.capture()
                    guard let self, self.active, !Task.isCancelled else { return }
                    self.frame = frame
                    if let reason { await self.stop(reason); return }
                    let delay = DiagnosticBudget.delay(collectionSeconds: (frame?.collectionMilliseconds ?? 0) / 1000, thermal: frame?.thermal ?? 0)
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                }
            }
            showController()
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: .activateIgnoringOtherApps)
        } catch { status = "검사 저장소를 만들지 못했습니다: \(error.localizedDescription)" }
    }
    func mark(_ action: String) {
        guard active, !saving else { return }
        let timestamp = NativeCPUReader.continuousSeconds
        let recorder = recorder
        Task {
            guard await recorder?.mark("manual", action, at: timestamp) == true else {
                lastMarker = "표식을 저장하지 못했습니다 · 기록 한도 또는 저장 상태를 확인하세요."
                return
            }
            let names = ["first-input": "첫 입력", "sidebar": "목록 이동", "attachment": "사진 첨부", "stutter": "끊김 발생"]
            lastMarker = "\(names[action] ?? action) · 표식 저장됨"
        }
    }
    func collectStack() {
        guard active, !saving else { return }
        Task { status = await recorder?.collectStack() ?? "검사를 먼저 시작하세요." }
    }
    func runReplay() {
        guard active, !saving, !replaying, let target = selected, let recorder else { return }
        replaying = true; replay.onStop = { [weak self] in self?.replayTask?.cancel() }
        replayTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await replay.run(target: target, repeats: repeats) { kind, detail in _ = await recorder.mark(kind, detail) }
                status = "자동 재현 종료 · 검사 기록은 계속됩니다."
            } catch {
                let detail = error is CancellationError ? "사용자가 자동 재현을 중단했습니다." : error.localizedDescription
                status = detail; await recorder.mark("auto-stopped", detail)
            }
            replaying = false; replay.onStop = nil
        }
    }
    func stopReplay() { replayTask?.cancel() }
    func stop(_ reason: String = "사용자 종료") async {
        if saving {
            while saving { try? await Task.sleep(nanoseconds: 20_000_000) }
            return
        }
        guard active, let recorder else { return }
        saving = true; collectionTask?.cancel(); collectionTask = nil
        replayTask?.cancel(); await replayTask?.value; replayTask = nil
        replay.cancelRegistration()
        do {
            let result = try await recorder.finish(reason)
            presentations[result.id] = DiagnosticPresentation(result)
            results.insert(result, at: 0); results = Array(results.prefix(20))
            presentations = presentations.filter { id, _ in results.contains { $0.id == id } }
            output = recorder.folder
            status = "저장됨 · \(result.diagnosticHeadline)"
        } catch { status = "결과 저장 실패: \(error.localizedDescription)" }
        self.recorder = nil; active = false; saving = false
        panel?.close(); panel = nil
        if reason == "사용자 종료" {
            NSApp.activate(ignoringOtherApps: true)
            resultWindow?.makeKeyAndOrderFront(nil)
        }
    }
    func showController() {
        if let panel { panel.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 365, height: 255),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Modore · 기록 중"
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DiagnosticController(service: self))
        panel.orderFrontRegardless(); self.panel = panel
    }
    func openResult(_ result: DiagnosticResult) { NSWorkspace.shared.open(root.appendingPathComponent(result.id.uuidString)) }
    func copyReport(_ result: DiagnosticResult) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.report, forType: .string)
    }
}

private struct DiagnosticController: View {
    @ObservedObject var service: AppDiagnosticService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(service.replaying ? "자동 재현 중 · Esc로 중단" : "\(service.selected?.name ?? "앱") 기록 중", systemImage: "record.circle.fill")
                .font(.headline).foregroundStyle(Color.accentColor)
            Text(service.frame.map { "\(Int($0.seconds))초 / 최대 5분 · CPU \($0.targetCPU.map { String(format: "%.1f%%", $0) } ?? "측정 중")" } ?? "측정 시작 중")
                .font(.callout).monospacedDigit()
            Text("동작하거나 끊긴 순간에 표식을 누르세요.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("첫 입력") { service.mark("first-input") }
                Button("목록 이동") { service.mark("sidebar") }
                Button("사진 첨부") { service.mark("attachment") }
                Button("끊김") { service.mark("stutter") }
            }.disabled(service.saving)
            Text(service.lastMarker ?? "고부하 증거는 자동으로 보존합니다.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                if service.replaying { Button("자동 조작 중단") { service.stopReplay() } }
                Spacer()
                Button(service.saving ? "저장 중…" : "종료하고 결과 보기") { Task { await service.stop() } }
                    .buttonStyle(.borderedProminent).disabled(service.saving)
            }
            Text("표식은 누른 시각이며 실제 조작 시각의 자동 판별은 아닙니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(width: 365, height: 255)
    }
}
