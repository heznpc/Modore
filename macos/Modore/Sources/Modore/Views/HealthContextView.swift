import AppKit
import SwiftUI

struct HealthContextView: View {
    @EnvironmentObject private var monitor: CPUWatchService
    @EnvironmentObject private var model: ScanModel
    let openRecovery: () -> Void
    let openWork: () -> Void
    @State private var copied = false
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("지금 이 Mac").font(.largeTitle.bold())
                        Text(monitor.enabled ? "10초마다 공간·RAM·스왑·CPU 관찰 · 앱 종료 시 중단" : "감시 꺼짐 · 아래 값은 마지막 관찰 기록입니다")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !monitor.enabled {
                        Button("감시 켜기") { Task { await monitor.setEnabled(true) } }
                    }
                    Button(copied ? "복사됨" : "상황 설명 복사") { copyContext() }
                        .disabled(monitor.snapshot == nil)
                }
                Text(monitor.notificationStatus).font(.caption).foregroundStyle(.secondary)
                if let error = monitor.journalError { Text(error).foregroundStyle(.orange) }
                if let snapshot = monitor.snapshot {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(snapshot.issues.isEmpty ? (snapshot.complete ? "관찰 범위에서 경고 없음" : "관찰값 확인 중") : snapshot.issues.joined(separator: " · "))
                                .font(.title2.bold())
                            Text(snapshot.summary).font(.headline)
                            Text(snapshot.explanation(from: monitor.journal.incidents.first?.first))
                            Text("관찰 시각 \(snapshot.date.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("공간 확보") { monitor.markAction("공간 확보 검토 열기"); openRecovery() }
                                Button("활동 모니터에서 작업 확인") {
                                    monitor.markAction("활동 모니터 열기")
                                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                                }
                                Button("조치 전 상태 기록") { monitor.markAction("사용자가 조치 전 상태 기록") }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    processSection(snapshot)
                } else { ProgressView("첫 관찰값을 읽는 중…") }
                sessionSection
                historySection
            }.padding(24)
        }
        .task {
            await monitor.refreshNotificationStatus()
            if model.sessionIndex == nil && !model.sessionIndexLoading { model.refreshSessionIndex() }
        }
    }

    private func processSection(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("부하가 큰 프로세스와 작업").font(.headline)
            Text("CPU·메모리 상위 각 5개. 메모리는 프로세스 상주량이며 공유 메모리가 포함될 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(snapshot.processes) { process in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(process.name).fontWeight(.medium)
                        Text("PID \(process.pid)").foregroundStyle(.secondary)
                        Spacer()
                        Text("CPU \(Int(process.cpu))% · RAM \(HealthSnapshot.bytes(process.residentBytes.map { Int64(clamping: $0) }))")
                    }
                    if let workspace = process.workspace {
                        Text(workspace).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        let matches = matchingSessions(workspace)
                        if !matches.isEmpty {
                            Button("같은 경로의 대화 \(matches.count)개 확인") {
                                model.sessionSearch = workspace
                                openWork()
                            }.font(.caption)
                            Text("경로 일치 후보 · 현재 프로세스를 실행한 세션인지 미확정")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else { Text("연결된 세션 메타데이터 없음").font(.caption).foregroundStyle(.secondary) }
                    } else { Text("작업 경로 미확인").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("이어서 볼 세션").font(.headline)
                Spacer()
                Button("목록 갱신") { model.refreshSessionIndex() }.disabled(model.sessionIndexLoading)
            }
            HStack {
                TextField("프로젝트·세션 찾기", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { model.sessionSearch = query; openWork() }
                Button("찾기") { model.sessionSearch = query; openWork() }
            }
            if model.sessionIndexLoading { ProgressView("세션 메타데이터 읽는 중…") }
            if let error = model.sessionIndexError { Text(error).foregroundStyle(.orange) }
            if let warning = model.sessionIndex?.coverage.warningText { Text(warning).font(.caption).foregroundStyle(.orange) }
            ForEach(Array((model.sessionIndex?.sessions ?? []).filter(\.isReadable).prefix(5))) { session in
                Button {
                    model.sessionSearch = session.workspace
                    model.selectedSessionSource = session.source
                    model.loadConversation(for: session)
                    openWork()
                } label: {
                    HStack {
                        Text(session.displayLabel)
                        Text(session.tool).foregroundStyle(.secondary)
                        Spacer()
                        Text(session.lastActive).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            Text("최근 세션 메타데이터입니다. 대화 내용은 세션을 열거나 검색을 실행할 때 읽습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("발생 기록과 조치 후 변화").font(.headline)
            ForEach(monitor.journal.incidents.prefix(10)) { incident in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(incident.issues.joined(separator: " · ")).fontWeight(.medium)
                        Text("\(incident.first.date.formatted()) · \(incident.interrupted ? "감시 중단 · 회복 미확인" : (incident.resolvedAt == nil ? "관찰 중" : "60초간 경고 기준 아래"))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(incident.latest.change(from: incident.first))
                        if let action = incident.action, let baseline = incident.actionBaseline {
                            Text("\(action) 이후: \(incident.latest.change(from: baseline))")
                            Text("조치의 인과 효과가 아닌 관찰된 변화입니다.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
            if monitor.journal.incidents.isEmpty { Text("아직 기록된 경고 상황이 없습니다.").foregroundStyle(.secondary) }
            RecoveryHistorySection()
        }
    }

    private func matchingSessions(_ workspace: String) -> [SessionIndexEntry] {
        (model.sessionIndex?.sessions ?? []).filter { $0.workspace == workspace }
    }

    private func copyContext() {
        guard let snapshot = monitor.snapshot else { return }
        let incident = monitor.journal.incidents.first
        var lines = ["Modore 관찰 \(snapshot.date.formatted())", snapshot.summary,
                     snapshot.explanation(from: incident?.first)]
        lines += snapshot.processes.map { "\($0.name) PID \($0.pid): CPU \(Int($0.cpu))%, RAM \(HealthSnapshot.bytes($0.residentBytes.map { Int64(clamping: $0) })) · 작업 경로 \($0.workspace ?? "미확인")" }
        if let incident { lines.append("최초 관찰 이후: \(snapshot.change(from: incident.first))") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
    }
}
