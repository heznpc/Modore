import AppKit
import SwiftUI

@MainActor
final class QAModel: ObservableObject {
    @Published var running = false
    @Published var saving = false
    @Published var elapsedSeconds = 0
    @Published var status = "원하는 만큼 사용한 뒤 측정 종료를 누르세요."
    @Published var output: URL?
    @Published var ratings = ["first-input": "미확인", "typing": "미확인", "sidebar": "미확인", "attachment": "미확인"]
    @Published var context = "현재 긴 대화"
    private var recorder: Recorder?
    private var timer: Timer?
    private var startTime: Double = 0
    private var captureIndex = -1
    private var stopped: (() -> Void)?
    let smoke: Bool

    init(smoke: Bool) { self.smoke = smoke }

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
            elapsedSeconds = 0
            running = true; captureIndex = -1
            status = "ChatGPT를 평소처럼 사용하세요. 끝났을 때 이 창에서 종료하면 됩니다."
            startTime = ProcessInfo.processInfo.systemUptime
            recorder?.start()
            tick()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch { status = "진단 폴더를 만들 수 없습니다: \(error.localizedDescription)" }
    }

    private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        if elapsedSeconds != Int(elapsed) { elapsedSeconds = Int(elapsed) }
        // Only the explicit smoke-test mode has an automatic stop. User runs
        // never advance an instruction or finish based on a countdown.
        if RecordingPolicy.shouldFinish(elapsed: elapsed, smoke: smoke) { finish(cancelled: false); return }
        let index = Int(elapsed / 20)
        if index != captureIndex {
            captureIndex = index
            recorder?.changePhase(Phase(id: String(format: "observation-%04d", index),
                title: "자유 측정", instruction: "User-controlled recording; no assumed action.", seconds: 10))
        }
    }

    func finish(cancelled: Bool, then: (() -> Void)? = nil) {
        if saving { stopped = then; return }
        guard running else { then?(); return }
        stopped = then
        timer?.invalidate(); timer = nil
        running = false; saving = true
        status = "결과를 저장하고 있습니다…"
        let folder = recorder?.folder
        recorder?.finish(cancelled: cancelled) { [weak self] detail in
            guard let self else { return }
            self.output = folder; self.saving = false
            self.status = detail
            self.saveRatings()
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
        status = "원하는 만큼 사용한 뒤 측정 종료를 누르세요."
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
                    Text("시작과 종료만 누르면, 조용히 기록합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.running { Text("\(model.elapsedSeconds)초").font(.title2.monospacedDigit().bold()) }
            }
            Divider()
            if model.smoke { Text("자동 점검 모드 · 사용자 재현 결과가 아닙니다").font(.caption).foregroundStyle(.orange) }
            if model.running {
                Text("측정 중").font(.title3.bold())
                Text(model.status).font(.body).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 58, alignment: .topLeading)
                Text("자동으로 넘어가는 단계나 종료 시간은 없습니다.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("이 창은 옆으로 옮겨두셔도 됩니다.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("측정 종료 · 저장") { model.finish(cancelled: false) }.buttonStyle(.borderedProminent)
                }
            } else if model.output != nil {
                Label(model.status, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                Text("어떤 동작에서 버벅였나요?").font(.headline)
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
                Text("켜두고 평소처럼 사용하세요.").font(.headline)
                Text("입력·목록 이동·사진 첨부를 원하는 순서와 속도로 해보세요.\n끝나면 돌아와 측정 종료를 누르면 됩니다.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("측정할 대화", selection: $model.context) {
                    Text("현재 긴 대화").tag("현재 긴 대화")
                    Text("짧은 기존 대화").tag("짧은 기존 대화")
                }.pickerStyle(.segmented).disabled(model.saving)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Button(model.saving ? "저장 중…" : "측정 시작") { model.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.saving)
            }
            Spacer(minLength: 0)
            Text("CPU · 주기적 호출 스택 · 오류 시각을 로컬에 저장합니다.\n화면 녹화, 키 입력 내용, 사진 내용은 수집하지 않습니다.")
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
