import AppKit
import SwiftUI

private struct HealthWorkbenchRoute: Identifiable { let id:String }

struct HealthContextView: View {
    @EnvironmentObject private var monitor: CPUWatchService
    @EnvironmentObject private var model: ScanModel
    let openRecovery: () -> Void
    let openWork: () -> Void
    let openStorageOverview: () -> Void
    let openDiagnosis: () -> Void
    let openSecurity: () -> Void
    @State private var copied = false
    @State private var query = ""
    @State private var environmentRoute: HealthWorkbenchRoute?
    @State private var appRecovery = false
    @State private var showHistory = false
    @State private var showProcesses = false

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:8) {
                        Text(L10n.text("내 Mac 작업실")).font(.system(size:34,weight:.bold))
                        HStack(spacing:8) {
                            Circle().fill(monitor.enabled ? Color.teal : Color.secondary).frame(width:7,height:7)
                            Text(monitor.enabled ? L10n.text("실시간 관찰") : L10n.text("관찰 꺼짐 · 마지막 기록"))
                            if let snapshot=monitor.snapshot { Text(snapshot.date.formatted(date:.omitted,time:.standard)).monospacedDigit() }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !monitor.enabled { Button(L10n.text("관찰 켜기")) { Task { await monitor.setEnabled(true) } } }
                    HStack(spacing:10) {
                        Button(copied ? L10n.text("복사됨") : L10n.text("상황 설명 복사")) { copyContext() }.disabled(monitor.snapshot == nil)
                        Button(L10n.text("조치 전 상태 기록")) { monitor.markAction(L10n.text("사용자가 조치 전 상태 기록")) }
                        Button(L10n.text("활동 모니터")) { NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Utilities/Activity Monitor.app")) }
                    }.buttonStyle(.bordered)

                }
                if let error = monitor.journalError { Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.orange) }
                if let snapshot=monitor.snapshot {
                    HealthDashboardTiles(snapshot:snapshot,peak:monitor.journal.incidents.compactMap(\.cpuPeak).first,storage:openStorageOverview,memory:{ appRecovery=true },cpu:{ showProcesses=true })
                    HStack(spacing:16) {
                        HealthActionTile(title:L10n.text("공간 비우기"),subtitle:L10n.text("전체 측정 · 정리 대상"),icon:"sparkles") { monitor.markAction(L10n.text("공간 확보 검토 열기"));openRecovery() }
                        HealthActionTile(title:L10n.text("작업대"),subtitle:L10n.text("기기 · 프로젝트 · SSD"),icon:"square.stack.3d.up") { environmentRoute=HealthWorkbenchRoute(id:"space") }
                    }
                    HStack(spacing:16) {
                        HealthActionTile(title:L10n.text("문제 점검"),subtitle:L10n.text("오류 · 시작 프로그램 · 상태 진단"),icon:"stethoscope",action:openDiagnosis)
                        HealthActionTile(title:L10n.text("권한·자동 실행 점검"),subtitle:L10n.text("앱 접근 권한 · 백그라운드 실행"),icon:"lock.shield",action:openSecurity)
                    }

                } else { ProgressView(L10n.text("상태를 읽고 있습니다")).frame(maxWidth:.infinity,minHeight:180) }
                HStack(spacing:16) {
                    HealthActionTile(title:L10n.text("프로젝트·대화"),subtitle:L10n.text("작업 찾아 이어가기"),icon:"folder",action:openWork)
                    HealthActionTile(title:L10n.text("조치 기록"),subtitle:L10n.text("실행 결과 · 전후 변화"),icon:"clock.arrow.circlepath") { showHistory=true }
                }
                Spacer(minLength:0)
            }.padding(24)
        }
        .navigationDestination(isPresented:Binding(get:{environmentRoute != nil},set:{if !$0 {environmentRoute=nil}})) { EnvironmentRetirementView(initialTab:environmentRoute?.id ?? "space") }
        .navigationDestination(isPresented:$showProcesses) {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    HStack { Text(L10n.text("실행 작업")).font(.largeTitle.bold());Spacer();Button(L10n.text("서버·가상머신 관리")) { environmentRoute=HealthWorkbenchRoute(id:"finish") } }
                    if let peak=monitor.journal.incidents.compactMap(\.cpuPeak).first {
                        Text(L10n.text("최근 부하 당시 · ") + peak.date.formatted()).font(.headline)
                        processSection(peak)
                    }
                    if let snapshot=monitor.snapshot { processSection(snapshot) }
                }.padding(24)
            }
        }
        .navigationDestination(isPresented:$appRecovery) { AppRecoveryView() }
        .navigationDestination(isPresented:$showHistory) { VStack { HStack { Text(L10n.text("발생 기록")).font(.title2.bold()); Spacer(); Button(L10n.text("닫기")) { showHistory=false } }; ScrollView { historySection } }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity) }
        .task {
            await monitor.refreshNotificationStatus()
            if model.sessionIndex == nil && !model.sessionIndexLoading { model.refreshSessionIndex() }
        }
    }

    private func processSection(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text(L10n.text("지금 자원을 쓰는 작업")).font(.title3.bold())
                Spacer()
                Text(L10n.text("CPU·메모리 상위 작업")).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
                ForEach(snapshot.processes) { process in
                    VStack(alignment:.leading,spacing:12) {
                        HStack(spacing:12) {
                            Image(systemName:process.name.contains("VirtualMachine") ? "server.rack" : "app").font(.title2).foregroundStyle(.teal)
                            Text(process.name.contains("VirtualMachine") ? L10n.text("가상머신") : process.name).font(.headline).lineLimit(1).help(process.name)
                            Spacer()
                        }
                        HStack(spacing:16) {
                            Label(snapshot.cpuAvailable ? "\(Int(process.cpu))%" : L10n.text("측정 중"),systemImage:"cpu")
                            Label(HealthSnapshot.bytes(process.residentBytes.map { Int64(clamping:$0) }),systemImage:"memorychip")
                        }.font(.callout.weight(.medium)).monospacedDigit()
                        if let workspace=process.workspace {
                            HStack {
                                Label(URL(fileURLWithPath:workspace).lastPathComponent,systemImage:"folder").lineLimit(1).help(workspace)
                                Spacer()
                                let matches=matchingSessions(workspace)
                                if !matches.isEmpty {
                                    Button("경로 일치 대화 \(matches.count)") { model.sessionSearch=workspace;openWork() }.buttonStyle(.plain).foregroundStyle(.teal)
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        } else { Label(L10n.text("프로젝트 연결 미확인"),systemImage:"link").font(.caption).foregroundStyle(.secondary) }
                    }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                        .background(Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:16))
                        .contextMenu { Text("PID \(process.pid)"); Text(process.name); Text(process.workspace ?? "작업 경로 미확인") }
                }
            }
            Text(L10n.text("CPU 100% = 코어 1개 · 메모리는 공유 영역을 포함한 상주량 · 경로 일치는 실행한 세션의 확정 근거가 아닙니다.")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("이어서 할 작업").font(.title3.bold())
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
            ForEach(Array((model.sessionIndex?.sessions ?? []).filter(\.isReadable).prefix(3))) { session in
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
                        Image(systemName:"arrow.up.right").foregroundStyle(.teal)
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:12)).contentShape(Rectangle())
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
        lines += snapshot.processes.map { "\($0.name) PID \($0.pid): CPU \(Int($0.cpu))%, RAM \(HealthSnapshot.bytes($0.residentBytes.map { Int64(clamping: $0) })) · 작업 경로 \($0.workspace ?? L10n.text("미확인"))" }
        if let incident { lines.append("최초 관찰 이후: \(snapshot.change(from: incident.first))") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
    }
}
