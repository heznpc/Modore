import AppKit
import SwiftUI

struct AppDiagnosticPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var service = AppDiagnosticService.shared
    @ObservedObject private var replay = AppDiagnosticService.shared.replay
    @State private var shownResultID: UUID?
    @State private var showAdvanced = false
    @State private var showHistory = false
    @State private var showMetrics = false
    @State private var showCollectionDetails = false
    @State private var reportCopied = false

    private var shownResult: DiagnosticResult? { service.results.first { $0.id == shownResultID } }
    private var stage: Int { service.active ? 1 : shownResult == nil ? 0 : 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("앱 버벅임 진단").font(.largeTitle.bold())
                    Text("평소처럼 앱을 사용하면 Modore가 부하를 기록하고, 동작 전후를 비교합니다.")
                        .foregroundStyle(.secondary)
                }
                steps
                Group {
                    if service.active { recording }
                    else if let result = shownResult { resultSummary(result) }
                    else { preparation }
                }
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: stage)
                if !service.active { history }
            }
            .padding(28)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            service.refreshApps()
            await service.loadHistory()
            if service.output != nil { shownResultID = service.results.first?.id }
        }
        .onChange(of: service.selectedPID) { _ in replay.reset() }
        .onChange(of: service.active) { active in
            if active { shownResultID = nil; reportCopied = false }
            else if service.output != nil { shownResultID = service.results.first?.id }
        }
        .onDisappear { replay.cancelRegistration() }
    }

    private var steps: some View {
        HStack(spacing: 12) {
            ForEach(Array(["앱 선택", "사용하며 기록", "결과 확인"].enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    Image(systemName: index < stage ? "checkmark.circle.fill" : "\(index + 1).circle\(index == stage ? ".fill" : "")")
                    Text(title).fontWeight(index == stage ? .semibold : .regular)
                }
                .foregroundStyle(index == stage ? Color.accentColor : Color.secondary)
                .accessibilityLabel("\(index + 1)단계 \(title)\(index == stage ? ", 현재 단계" : "")")
                if index < 2 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .font(.callout)
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("어떤 앱에서 느려지나요?").font(.title3.bold())
                    HStack {
                        Picker("대상 앱", selection: $service.selectedPID) {
                            Text("실행 중인 앱 선택").tag(Int32(0))
                            ForEach(service.apps) { Text($0.name).tag($0.pid) }
                        }
                        Button { service.refreshApps() } label: { Image(systemName: "arrow.clockwise") }
                            .help("실행 중인 앱 새로고침")
                    }
                    if service.apps.isEmpty {
                        Text("검사할 앱을 실행한 뒤 새로고침을 누르세요.").foregroundStyle(.secondary)
                    }
                    TextField("상황 메모 (선택) · 예: 긴 대화에서 첫 입력", text: $service.condition)
                        .textFieldStyle(.roundedBorder)
                    Divider()
                    Text("시작한 뒤에는 이렇게 하세요").font(.headline)
                    instruction("1", "대상 앱으로 돌아가 평소처럼 사용하세요.")
                    instruction("2", "첫 입력·목록 이동·사진 첨부 때 작은 컨트롤러에 표식을 남기세요.")
                    instruction("3", "증상을 확인한 뒤 ‘종료하고 결과 보기’를 누르세요.")
                    Text("5분이 되면 자동 저장합니다. 기록 중인지는 작은 컨트롤러에서 항상 확인할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { service.start() } label: {
                        Label(service.selected.map { "\($0.name) 검사 시작" } ?? "검사 시작", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(service.selected == nil || service.saving)
                    .keyboardShortcut(.return, modifiers: .command)
                    if service.status != AppDiagnosticService.readyStatus {
                        Text(service.status).font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            collectionDetails
            advanced
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(service.saving ? "결과를 저장하고 있습니다" : "\(service.selected?.name ?? "앱") 기록 중", systemImage: service.saving ? "square.and.arrow.down" : "record.circle.fill")
                            .font(.title3.bold()).foregroundStyle(service.saving ? Color.primary : Color.accentColor)
                        Spacer()
                        Text(service.frame.map { "\(Int($0.seconds))초 / 최대 5분" } ?? "시작 중")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text("대상 앱에서 문제가 생기는 동작을 해보세요. 아래 표식은 누른 시각을 기록합니다.")
                    markerButtons
                    if let marker = service.lastMarker { Label(marker, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
                    Divider()
                    HStack {
                        Button("작은 컨트롤러 다시 보기") { service.showController() }
                        Spacer()
                        Button("종료하고 결과 보기") { Task { await service.stop() } }
                            .buttonStyle(.borderedProminent).disabled(service.saving)
                    }
                    Text(service.status).font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let frame = service.frame {
                HStack(spacing: 28) {
                    metric("앱·작업 합산 CPU", frame.targetCPU)
                    metric("화면 처리 CPU", frame.rendererCPU)
                }
                DisclosureGroup("수집 상태 자세히", isExpanded: $showMetrics) {
                    HStack(spacing: 24) {
                        metric("Modore 전체 CPU", frame.observerCPU)
                        metric("스택 도구 CPU", frame.samplerCPU)
                        VStack(alignment: .leading) {
                            Text("수집 비용").font(.caption)
                            Text(String(format: "%.1f ms", frame.collectionMilliseconds)).monospacedDigit()
                        }
                    }.padding(.top, 8)
                }
            }
            advanced
        }
    }

    private var markerButtons: some View {
        HStack {
            Button("첫 입력") { service.mark("first-input") }
            Button("목록 이동") { service.mark("sidebar") }
            Button("사진 첨부") { service.mark("attachment") }
            Button("끊김 발생") { service.mark("stutter") }
        }.disabled(service.saving)
    }

    private func resultSummary(_ result: DiagnosticResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("검사 결과", systemImage: "checkmark.circle.fill").font(.title3.bold())
                Text("\(result.target.name) · \(result.started.formatted())").font(.callout).foregroundStyle(.secondary)
                if let presentation = service.presentations[result.id] {
                    Text(presentation.headline).font(.title3.weight(.semibold))
                    ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.callout).textSelection(.enabled)
                    }
                    if presentation.actions.isEmpty {
                        Text("동작 표식이 없어 검사 전체의 부하를 요약했습니다.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 30) {
                    metric("평균 CPU", result.meanCPU)
                    metric("최고 CPU", result.peakCPU)
                }
                Text("CPU 기록은 앱이 바빴던 구간을 보여줍니다. 화면 지연 시간이나 근본 원인을 단독으로 확정하는 결과는 아닙니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button(reportCopied ? "요약 복사됨" : "결과 요약 복사") { service.copyReport(result); reportCopied = true }
                        .buttonStyle(.borderedProminent)
                    Button("저장 폴더 열기") { service.openResult(result) }
                    Spacer()
                    Button("다른 조건으로 검사") { shownResultID = nil; reportCopied = false }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var collectionDetails: some View {
        DisclosureGroup("수집하는 정보와 자동 저장", isExpanded: $showCollectionDetails) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CPU와 프로세스별 부하, 누른 표식과 상황 메모를 이 Mac에 저장합니다. 대화·키 입력 내용·사진은 수집하지 않습니다.")
                Text("고부하가 생기면 원인 분석용 스택을 3초씩 최대 2회 자동 보존합니다. 스택에는 로컬 경로가 포함될 수 있어 비공개 폴더에 저장합니다.")
                Text("수집 부담이나 발열이 커지면 간격을 늘립니다. 스택은 수동 포함 총 3회, 30초 이상 간격으로 제한합니다.")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    private var advanced: some View {
        DisclosureGroup("고급 · 같은 동작을 자동으로 반복하기", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Text("반복 비교가 필요할 때만 설정하세요. 빈 입력창에 시험 문자열을 입력하고 목록으로 포인터를 옮긴 뒤 문자열을 지웁니다. 메시지는 전송하지 않습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("접근성 권한 설정") { replay.requestPermission() }
                        Button("등록 취소") { replay.cancelRegistration() }
                    }
                    HStack {
                        Button(replay.hasInput ? "입력창 다시 등록" : "빈 입력창 등록") { if let app = service.selected { replay.register(input: true, target: app) } }
                        Button(replay.hasHover ? "목록 다시 등록" : "목록 위치 등록") { if let app = service.selected { replay.register(input: false, target: app) } }
                    }
                }.disabled(service.replaying || service.saving || service.selected == nil)
                Text(replay.message).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Stepper("반복 \(service.repeats)회", value: $service.repeats, in: 1...3).frame(width: 160).disabled(service.replaying)
                    Button(service.replaying ? "자동 조작 중단" : "등록한 동작 재현") {
                        if service.replaying { service.stopReplay() } else { service.runReplay() }
                    }.disabled(!service.active || !replay.hasInput || !replay.hasHover || service.saving)
                }
                Text(service.active ? "Esc 또는 중단 버튼으로 자동 조작을 멈춥니다. 사진 첨부는 직접 진행하세요." : "등록을 마친 뒤 검사를 시작하면 자동 재현 버튼을 사용할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 12)
        }
    }

    private var history: some View {
        DisclosureGroup("이전 검사 \(service.results.count)개 보기·비교", isExpanded: $showHistory) {
            VStack(alignment: .leading, spacing: 12) {
                if service.results.isEmpty {
                    Text("첫 검사를 저장하면 여기에 나타납니다.").foregroundStyle(.secondary)
                } else {
                    Picker("비교 기준", selection: $service.baselineID) {
                        Text("비교하지 않음").tag(Optional<UUID>.none)
                        ForEach(service.results) { result in
                            Text("\(result.target.name) · \(result.started.formatted()) · \(result.condition)").tag(Optional(result.id))
                        }
                    }
                    ForEach(service.results.prefix(10)) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(result.target.name) · \(result.condition)").font(.headline)
                                    Text(result.started.formatted()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("결과 보기") { shownResultID = result.id; reportCopied = false }
                            }
                            if let baseline = service.baseline, baseline.id != result.id {
                                if let warning = result.comparisonWarning(baseline) { Text(warning).foregroundStyle(.orange).font(.caption) }
                                if let before = baseline.meanCPU, let after = result.meanCPU {
                                    Text(String(format: "기준 대비 CPU 평균 %+.1f%%p · 체감 개선의 증명은 아닙니다.", after - before)).font(.caption)
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }.padding(.top, 12)
        }
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.callout.weight(.semibold)).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.callout)
        }
    }

    private func metric(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f%%", $0) } ?? "—").font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

struct AppDiagnosticLauncher: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "app-diagnostic") } label: {
            Label("앱 버벅임 진단", systemImage: "cursorarrow.motionlines")
        }
    }
}
