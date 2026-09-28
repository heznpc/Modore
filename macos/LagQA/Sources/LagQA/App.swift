import AppKit
import SwiftUI

@MainActor
final class QAModel: ObservableObject {
    @Published var running = false
    @Published var saving = false
    @Published var phaseIndex = -1
    @Published var remaining = 80
    @Published var phaseRemaining = 8
    @Published var status = "시작 후 ChatGPT로 돌아가 음성 안내를 따라주세요."
    @Published var output: URL?
    @Published var voiceEnabled = true
    @Published var ratings = ["first-input": "미확인", "typing": "미확인", "sidebar": "미확인", "attachment": "미확인"]
    @Published var context = "현재 긴 대화"
    private var recorder: Recorder?
    private var timer: Timer?
    private var startTime: Double = 0
    private var phases = Phase.standard
    private let speech = NSSpeechSynthesizer()
    private var stopped: (() -> Void)?
    let smoke: Bool

    init(smoke: Bool) {
        self.smoke = smoke
        if let voice = NSSpeechSynthesizer.availableVoices.first(where: {
            (NSSpeechSynthesizer.attributes(forVoice: $0)[.localeIdentifier] as? String)?.hasPrefix("ko") == true
        }) { speech.setVoice(voice) }
        speech.rate = 205
    }

    func speak(_ text: String) {
        guard voiceEnabled, !smoke else { return }
        speech.stopSpeaking()
        if !speech.startSpeaking(text) { NSSound.beep() }
    }

    func start() {
        guard !running, !saving else { return }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first?.processIdentifier else {
            status = "ChatGPT 앱을 먼저 실행해 주세요."
            return
        }
        do {
            recorder = try Recorder(mainPID: pid, smoke: smoke)
            output = nil
            ratings = ["first-input": "미확인", "typing": "미확인", "sidebar": "미확인", "attachment": "미확인"]
            phases = smoke ? Phase.standard.map { Phase(id: $0.id, title: $0.title, instruction: $0.instruction,
                seconds: ["first-input", "sidebar", "attachment"].contains($0.id) ? 3 : 1) } : Phase.standard
            remaining = phases.reduce(0) { $0 + $1.seconds }
            running = true; phaseIndex = -1
            startTime = ProcessInfo.processInfo.systemUptime
            recorder?.start()
            tick()
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch { status = "진단 폴더를 만들 수 없습니다: \(error.localizedDescription)" }
    }

    private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let secondsLeft = max(0, Int(ceil(Double(phases.reduce(0) { $0 + $1.seconds }) - elapsed)))
        if remaining != secondsLeft { remaining = secondsLeft }
        guard let position = Phase.position(at: elapsed, phases: phases) else { finish(cancelled: false); return }
        if phaseRemaining != position.remaining { phaseRemaining = position.remaining }
        if position.index != phaseIndex {
            phaseIndex = position.index
            status = phases[phaseIndex].instruction
            recorder?.changePhase(phases[phaseIndex])
            speak(status)
        }
    }

    func finish(cancelled: Bool, then: (() -> Void)? = nil) {
        if saving { stopped = then; return }
        guard running else { then?(); return }
        stopped = then
        timer?.invalidate(); timer = nil
        speech.stopSpeaking()
        running = false; saving = true
        status = "결과를 저장하고 있습니다…"
        let folder = recorder?.folder
        recorder?.finish(cancelled: cancelled) { [weak self] detail in
            guard let self else { return }
            self.output = folder; self.saving = false
            self.status = detail
            self.saveRatings()
            self.speak(cancelled ? "진단을 중단했습니다. 결과는 저장했습니다." : "진단이 끝났습니다. QA 앱에서 버벅였던 구간을 표시해 주세요.")
            self.stopped?(); self.stopped = nil
        }
    }

    func saveRatings() {
        guard let folder = output else { return }
        do {
            let object: [String: Any] = ["context": context, "ratings": ratings,
                                       "note": "User ratings; not automatically measured input latency."]
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("user-observations.json"), options: .atomic)
        } catch { status = "체감 결과 저장 실패: \(error.localizedDescription)" }
    }

    func copySummary() {
        guard let folder = output, var text = try? String(contentsOf: folder.appendingPathComponent("report.md")) else { return }
        text += "\n## 사용자 체감\n\n대화 조건: \(context)\n"
        for phase in Phase.standard where ratings[phase.id] != nil {
            text += "- \(phase.title): \(ratings[phase.id] ?? "미확인")\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reset() {
        output = nil
        status = "시작 후 ChatGPT로 돌아가 음성 안내를 따라주세요."
    }
}

struct QAView: View {
    @ObservedObject var model: QAModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform.path.ecg").font(.title).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ChatGPT 끊김 진단").font(.title2.bold())
                    Text("앱에서 시작하고, 음성 안내대로 재현하세요.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.running { Text("\(model.remaining)초").font(.title2.monospacedDigit().bold()) }
            }
            Divider()
            if model.smoke { Text("자동 점검 모드 · 사용자 재현 결과가 아닙니다").font(.caption).foregroundStyle(.orange) }
            if model.running {
                Text(Phase.standard[model.phaseIndex].title).font(.title3.bold())
                Text(model.status).font(.body).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 58, alignment: .topLeading)
                ProgressView(value: Double(80 - model.remaining), total: 80)
                Text("이 구간 \(model.phaseRemaining)초 남음 · 메시지는 전송하지 마세요.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("이 창은 옆으로 옮겨두셔도 됩니다.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("중단하고 저장") { model.finish(cancelled: true) }
                }
            } else if model.output != nil {
                Label(model.status, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                Text("어느 구간에서 버벅였나요?").font(.headline)
                ForEach(Phase.standard.filter { model.ratings[$0.id] != nil }, id: \.id) { phase in
                    HStack {
                        Text(phase.title).frame(width: 114, alignment: .leading)
                        Picker(phase.title, selection: Binding(get: { model.ratings[phase.id] ?? "미확인" }, set: {
                            model.ratings[phase.id] = $0; model.saveRatings()
                        })) {
                            Text("미확인").tag("미확인")
                            Text("없음").tag("부드러움")
                            Text("약함").tag("조금 끊김")
                            Text("심함").tag("심하게 끊김")
                            Text("안 함").tag("시도 안 함")
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                }
                HStack {
                    Button("결과 폴더 열기") { if let folder = model.output { NSWorkspace.shared.open(folder) } }
                    Button("요약 복사") { model.copySummary() }
                    Spacer()
                    Button("다시 측정") { model.reset() }
                }
            } else {
                Text("80초 동안 안내에 맞춰 평소처럼 조작하면 됩니다.").font(.headline)
                Text("대기 → 첫 입력 → 연속 입력 → 목록 이동 → 사진 첨부\n사진 한 장을 미리 준비해 주세요.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("측정할 대화", selection: $model.context) {
                    Text("현재 긴 대화").tag("현재 긴 대화")
                    Text("짧은 기존 대화").tag("짧은 기존 대화")
                }.pickerStyle(.segmented).disabled(model.saving)
                HStack {
                    Toggle("음성 안내", isOn: $model.voiceEnabled)
                    Button("음성 확인") { model.speak("음성 안내가 준비되었습니다. 시작을 누르면 진단을 진행합니다.") }
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Button(model.saving ? "저장 중…" : "80초 진단 시작") { model.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.saving)
            }
            Spacer(minLength: 0)
            Text("CPU · 구간별 호출 스택 · 오류 시각을 로컬에 저장합니다.\n화면 녹화, 키 입력 내용, 사진 내용은 수집하지 않습니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(22).frame(width: 490, height: 430)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let model = QAModel(smoke: CommandLine.arguments.contains("--smoke-test"))
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "LagQA 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 430),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ChatGPT 끊김 진단 · Heznpc"
        window.contentView = NSHostingView(rootView: QAView(model: model))
        window.level = .floating
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if model.smoke { model.start() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.running || model.saving else { return .terminateNow }
        model.finish(cancelled: true) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct LagQA {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
