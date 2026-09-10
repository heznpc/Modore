import AppKit
import SwiftUI

struct HealthContextView: View {
    @EnvironmentObject private var monitor: CPUWatchService
    @EnvironmentObject private var model: ScanModel
    let openRecovery: () -> Void
    let openWork: () -> Void
    let openStorageOverview: () -> Void
    @State private var copied = false
    @State private var query = ""
    @State private var environmentRecovery = false
    @State private var appRecovery = false
    @State private var showHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("지금 이 Mac").font(.system(size:34,weight:.bold))
                        HStack(spacing:8) {
                            Circle().fill(monitor.enabled ? Color.teal : Color.secondary).frame(width:7,height:7)
                            Text(monitor.enabled ? "실시간 관찰" : "관찰 꺼짐 · 마지막 기록")
                            if let snapshot=monitor.snapshot { Text(snapshot.date.formatted(date:.omitted,time:.standard)).monospacedDigit() }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !monitor.enabled { Button("관찰 켜기") { Task { await monitor.setEnabled(true) } } }
                    Menu("기록·도구") {
                        Button("발생 기록과 조치 후 변화") { showHistory=true }
                        Button(copied ? "복사됨" : "상황 설명 복사") { copyContext() }.disabled(monitor.snapshot == nil)
                        Button("조치 전 상태 기록") { monitor.markAction("사용자가 조치 전 상태 기록") }
                        Button("활동 모니터") { NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Utilities/Activity Monitor.app")) }
                        Text(monitor.notificationStatus)
                    }
                }
                if let error = monitor.journalError { Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.orange) }
                if let snapshot=monitor.snapshot {
                    HealthDashboardTiles(snapshot:snapshot,storage:openStorageOverview,memory:{ appRecovery=true },cpu:{ environmentRecovery=true })
                    if !snapshot.issues.isEmpty {
                        Label(snapshot.issues.joined(separator:" · "),systemImage:"exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                    }
                    HStack(spacing:16) {
                        HealthActionTile(title:"공간 비우기",subtitle:"전체 측정 · 정리 대상",icon:"sparkles") { monitor.markAction("공간 확보 검토 열기");openRecovery() }
                        HealthActionTile(title:"작업대",subtitle:"기기 · 프로젝트 · SSD",icon:"square.stack.3d.up") { environmentRecovery=true }
                    }
                    processSection(snapshot)
                } else { ProgressView("상태를 읽고 있습니다").frame(maxWidth:.infinity,minHeight:180) }
                sessionSection
                Button { showHistory=true } label: {
                    HStack { Label("발생 기록과 조치 후 변화",systemImage:"clock.arrow.circlepath"); Spacer(); Text("기록 보기"); Image(systemName:"arrow.right") }.padding(18).contentShape(Rectangle())
                }.buttonStyle(.plain).background(Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:14))
            }.padding(24)
        }
        .sheet(isPresented:$environmentRecovery) { EnvironmentRetirementView() }
        .sheet(isPresented:$appRecovery) { AppRecoveryView() }
        .sheet(isPresented:$showHistory) { VStack { HStack { Text("발생 기록").font(.title2.bold()); Spacer(); Button("닫기") { showHistory=false } }; ScrollView { historySection } }.padding(24).frame(width:800,height:650) }
        .task {
            await monitor.refreshNotificationStatus()
            if model.sessionIndex == nil && !model.sessionIndexLoading { model.refreshSessionIndex() }
        }
    }

    private func processSection(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("지금 자원을 쓰는 작업").font(.title3.bold())
                Spacer()
                Text("CPU·메모리 상위 작업").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
                ForEach(snapshot.processes) { process in
                    VStack(alignment:.leading,spacing:12) {
                        HStack(spacing:12) {
                            Image(systemName:process.name.contains("VirtualMachine") ? "server.rack" : "app").font(.title2).foregroundStyle(.teal)
                            Text(process.name.contains("VirtualMachine") ? "가상머신" : process.name).font(.headline).lineLimit(1).help(process.name)
                            Spacer()
                        }
                        HStack(spacing:16) {
                            Label(snapshot.cpuAvailable ? "\(Int(process.cpu))%" : "측정 중",systemImage:"cpu")
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
                        } else { Label("프로젝트 연결 미확인",systemImage:"link").font(.caption).foregroundStyle(.secondary) }
                    }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                        .background(Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:16))
                        .contextMenu { Text("PID \(process.pid)"); Text(process.name); Text(process.workspace ?? "작업 경로 미확인") }
                }
            }
            Text("CPU 100% = 코어 1개 · 메모리는 공유 영역을 포함한 상주량 · 경로 일치는 실행한 세션의 확정 근거가 아닙니다.").font(.caption2).foregroundStyle(.secondary)
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
        lines += snapshot.processes.map { "\($0.name) PID \($0.pid): CPU \(Int($0.cpu))%, RAM \(HealthSnapshot.bytes($0.residentBytes.map { Int64(clamping: $0) })) · 작업 경로 \($0.workspace ?? "미확인")" }
        if let incident { lines.append("최초 관찰 이후: \(snapshot.change(from: incident.first))") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
    }
}
