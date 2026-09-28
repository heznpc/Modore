import AppKit
import SwiftUI

struct AppDiagnosticPage: View {
    @StateObject private var service = AppDiagnosticService.shared
    @ObservedObject private var replay = AppDiagnosticService.shared.replay
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("앱 재현 검사").font(.largeTitle.bold())
                Text("문제가 생기는 동작과 부하를 함께 기록하고, 같은 동작을 반복해 비교합니다.").foregroundStyle(.secondary)
                GroupBox("검사 대상") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Picker("실행 중인 앱", selection: $service.selectedPID) {
                                Text("앱 선택").tag(Int32(0))
                                ForEach(service.apps) { Text($0.name).tag($0.pid) }
                            }.disabled(service.active)
                            Button("새로고침") { service.refreshApps() }.disabled(service.active)
                        }
                        TextField("조건 메모 · 예: 긴 대화 / 새 대화", text: $service.condition).textFieldStyle(.roundedBorder).disabled(service.active)
                        Text("메모는 로컬 결과에만 저장합니다. 대화·키 입력 내용·사진은 수집하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                        Text("고부하가 발생하면 원인 추적용 스택을 자동 보존합니다(3초씩 최대 2회). 스택은 로컬 경로를 포함할 수 있으며 비공개 폴더에 저장됩니다.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if service.active {
                                Button("작은 컨트롤러 표시") { service.showController() }
                                Button("검사 종료·저장") { Task { await service.stop() } }.disabled(service.saving)
                            } else {
                                Button("검사 시작") { service.start() }.buttonStyle(.borderedProminent).disabled(service.selected == nil)
                            }
                            Text(service.status).font(.callout)
                        }
                    }.padding(8)
                }
                GroupBox("자동 재현 · 선택 사항") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("빈 입력창에 시험 문자열 입력 → 목록으로 포인터 이동 → 시험 문자열 제거. 메시지는 전송하지 않습니다. 앱이 접근성 요소를 제공해야 사용할 수 있습니다.")
                        HStack {
                            Button("접근성 권한 설정") { replay.requestPermission() }
                            Button(replay.hasInput ? "입력창 다시 등록" : "빈 입력창 등록") { if let app = service.selected { replay.register(input: true, target: app) } }
                            Button(replay.hasHover ? "목록 다시 등록" : "목록 위치 등록") { if let app = service.selected { replay.register(input: false, target: app) } }
                            Button("등록 취소") { replay.cancelRegistration() }
                        }.disabled(service.replaying || service.saving)
                        Text(replay.message).font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Stepper("반복 \(service.repeats)회", value: $service.repeats, in: 1...3).frame(width: 160).disabled(service.replaying)
                            Button(service.replaying ? "자동 조작 중단" : "등록 동작 재현") {
                                if service.replaying { service.stopReplay() } else { service.runReplay() }
                            }.disabled(!service.active || !replay.hasInput || !replay.hasHover || service.saving)
                        }
                        Text("자동 조작은 이 버튼을 눌러야 시작됩니다. Esc 또는 중단 버튼으로 멈춥니다. 사진 첨부는 직접 실행하면서 컨트롤러의 표식을 누르세요.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                if let frame = service.frame {
                    HStack(spacing: 30) {
                        metric("앱·작업 합산 CPU", frame.targetCPU)
                        metric("Renderer CPU", frame.rendererCPU)
                        metric("Modore 전체 CPU", frame.observerCPU)
                        metric("스택 도구 CPU", frame.samplerCPU)
                        VStack(alignment: .leading) { Text("수집 비용").font(.caption); Text(String(format: "%.1f ms", frame.collectionMilliseconds)).monospacedDigit() }
                    }
                }
                history
                Text("검사는 최대 5분입니다. 수집 부담이나 발열이 커지면 간격을 늘립니다. 고부하 스택은 자동 최대 2회, 수동 포함 총 3회, 30초 이상 간격으로 수집하며 발열이 높을 때는 자동 수집을 건너뜁니다. 낮은 CPU만으로 문제가 해결됐다고 판정하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .task { service.refreshApps(); await service.loadHistory() }
        .onChange(of: service.selectedPID) { _ in replay.reset() }
        .onDisappear { replay.cancelRegistration() }
    }
    private func metric(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption); Text(value.map { String(format: "%.1f%%", $0) } ?? "—").monospacedDigit() }
    }
    private var history: some View {
        GroupBox("저장 결과·전후 비교") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("비교 기준", selection: $service.baselineID) {
                    Text("선택 안 함").tag(Optional<UUID>.none)
                    ForEach(service.results) { result in Text("\(result.target.name) · \(result.started.formatted()) · \(result.condition)").tag(Optional(result.id)) }
                }
                ForEach(service.results.prefix(10)) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(result.target.name) · \(result.condition)").font(.headline)
                            Text(result.started.formatted()).font(.caption)
                            Spacer()
                            Button("공유 요약 복사") { service.copyReport(result) }
                            Button("결과 폴더") { service.openResult(result) }
                        }
                        Text("평균 \(result.meanCPU.map { String(format: "%.1f%%", $0) } ?? "—") · 최대 \(result.peakCPU.map { String(format: "%.1f%%", $0) } ?? "—") · \(result.finishReason)")
                        if let presentation = service.presentations[result.id] {
                            Text(presentation.headline).font(.callout.bold())
                            ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, text in
                                Text(text).font(.callout).textSelection(.enabled)
                            }
                        }
                        if let baseline = service.baseline, baseline.id != result.id {
                            if let warning = result.comparisonWarning(baseline) { Text(warning).foregroundStyle(.orange).font(.caption) }
                            if let before = baseline.meanCPU, let after = result.meanCPU {
                                Text(String(format: "기준 대비 CPU 평균 %+.1f%%p · 체감 개선의 증명은 아닙니다.", after - before)).font(.caption)
                            }
                        }
                    }.padding(.vertical, 8)
                    Divider()
                }
                if service.results.isEmpty { Text("아직 저장된 검사가 없습니다.").foregroundStyle(.secondary) }
            }.padding(8)
        }
    }
}

struct AppDiagnosticLauncher: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "app-diagnostic") } label: {
            Label("앱 재현 검사", systemImage: "cursorarrow.motionlines")
        }
    }
}
