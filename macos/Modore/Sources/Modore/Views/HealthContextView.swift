import AppKit
import SwiftUI

private struct HealthWorkbenchRoute: Identifiable { let id:String }

struct HealthContextView: View {
    @EnvironmentObject private var monitor: CPUWatchService
    @EnvironmentObject private var model: ScanModel
    @Binding var resourceFocus: HealthResourceFocus?
    let openRecovery: () -> Void
    let openWork: () -> Void
    let openStorageOverview: () -> Void
    let openDiagnosis: () -> Void
    let openSecurity: () -> Void
    let openRecheck: () -> Void
    let openAppDiagnostic: () -> Void
    let openActivity: () -> Void
    @State private var copied = false
    @State private var environmentRoute: HealthWorkbenchRoute?
    @State private var appRecovery = false
    @State private var showHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = monitor.journalError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    observation(at: context.date)
                }
                HealthWorkflowActions(
                    diagnose: openAppDiagnostic,
                    review: openDiagnosis,
                    results: openActivity
                )
            }
            .padding(28)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showHistory = true } label: { Label(L10n.text("관찰 기록"), systemImage: "clock.arrow.circlepath") }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L10n.text("Mac 재점검"), action: openRecheck)
                    Button(L10n.text("권한·자동 실행 점검"), action: openSecurity)
                    Button(L10n.text("기기·개발 환경 관리")) { environmentRoute = HealthWorkbenchRoute(id: "space") }
                    Divider()
                    Button(copied ? L10n.text("복사됨") : L10n.text("상황 설명 복사")) { copyContext() }.disabled(monitor.snapshot == nil)
                    Button(L10n.text("조치 전 상태 기록")) { monitor.markAction(L10n.text("사용자가 조치 전 상태 기록")) }.disabled(!hasCurrentSnapshot)
                    Button(L10n.text("활동 모니터")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                } label: { Label(L10n.text("추가 점검"), systemImage: "ellipsis.circle") }
            }
        }
        .navigationDestination(isPresented:Binding(get:{environmentRoute != nil},set:{if !$0 {environmentRoute=nil}})) { EnvironmentRetirementView(initialTab:environmentRoute?.id ?? "space") }
        .navigationDestination(isPresented: Binding(
            get: { resourceFocus != nil }, set: { if !$0 { resourceFocus = nil } }
        )) {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    HStack {
                        Text((resourceFocus ?? .memory).title).font(.largeTitle.bold())
                        Spacer()
                    }
                    if resourceFocus == .memory {
                        MemoryDiagnosisView()
                    } else {
                    Text(L10n.text(resourceFocus == .cpu
                        ? "필요 없는 빌드·테스트는 실행한 앱에서 중단하세요. 계속 높은 앱은 작업을 저장한 뒤 재시작을 검토하세요."
                        : "사용하지 않는 앱·탭을 닫으세요. 계속 메모리를 많이 쓰는 앱은 작업을 저장한 뒤 재시작을 검토하세요."))
                    HStack {
                        Button(L10n.text("앱 선택·재시작 검토")) { appRecovery = true }
                            .buttonStyle(.borderedProminent)
                        Button(L10n.text("활동 모니터 열기")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                        Button(L10n.text("서버·가상머신 관리")) { environmentRoute = HealthWorkbenchRoute(id: "finish") }
                    }
                    Text(L10n.text("순위는 원인 확정이 아닙니다. 시스템 프로세스는 강제 종료 대상으로 권하지 않습니다."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let snapshot = monitor.snapshot {
                        Text(hasCurrentSnapshot
                             ? snapshot.summary
                             : L10n.text("마지막 관찰 · 현재 상태 미확인"))
                            .font(.headline)
                        Text(L10n.format("관찰 시각 %@", snapshot.date.formatted())).font(.callout).foregroundStyle(.secondary)
                        processSection(snapshot)
                    } else {
                        Text(L10n.text("새 관찰이 도착하면 사용량을 표시합니다."))
                    }
                    if resourceFocus == .cpu, let peak = monitor.journal.incidents.compactMap(\.cpuPeak).first {
                        DisclosureGroup(L10n.text("최근 부하 당시 · ") + peak.date.formatted()) {
                            processSection(peak)
                        }
                    }
                    }
                }.padding(24)
            }
        }
        .navigationDestination(isPresented:$appRecovery) { AppRecoveryView() }
        .navigationDestination(isPresented:$showHistory) { VStack { HStack { Text(L10n.text("발생 기록")).font(.title2.bold()); Spacer(); Button(L10n.text("닫기")) { showHistory=false } }; ScrollView { historySection } }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity) }
        .task {
            await monitor.refreshNotificationStatus()
        }
        .onChange(of: resourceFocus) { focus in
            if focus != nil && model.sessionIndex == nil && !model.sessionIndexLoading { model.refreshSessionIndex() }
        }
    }

    private var hasCurrentSnapshot: Bool {
        monitor.enabled && monitor.snapshot?.isFresh() == true
    }

    @ViewBuilder
    private func observation(at date: Date) -> some View {
        if let snapshot = monitor.snapshot {
            let current = monitor.enabled && snapshot.isFresh(at: date)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(current ? L10n.text("최근 관찰") : L10n.text("마지막 관찰 · 현재 상태 미확인"),
                          systemImage: current ? "waveform.path.ecg" : "clock")
                    Spacer()
                    Text(snapshot.date.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
                    if !monitor.enabled {
                        Button(L10n.text("관찰 켜기")) { Task { await monitor.setEnabled(true) } }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if current {
                    HStack(spacing: 16) {
                        Image(systemName: snapshot.issues.isEmpty ? (snapshot.complete ? "checkmark.circle" : "questionmark.circle") : "exclamationmark.circle")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(snapshot.issues.isEmpty ? Color.secondary : .orange).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(snapshot.issues.isEmpty ? (snapshot.complete ? L10n.text("관찰 범위에서 현재 경고 기준 아래입니다.") : L10n.text("일부 관찰값이 없어 정상 여부를 확정하지 못했습니다.")) : snapshot.issues.map(L10n.text).joined(separator: " · "))
                                .font(.title2.weight(.semibold))
                            if !snapshot.issues.isEmpty {
                                Text(snapshot.explanation(from: monitor.journal.incidents.first?.first)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        if !snapshot.issues.isEmpty {
                            Button(L10n.text("확인")) {
                                if snapshot.storagePressure?.needsRecovery == true { openRecovery() }
                                else { resourceFocus = (snapshot.memoryPressure ?? 0) >= 2 ? .memory : .cpu }
                            }.modoreGlassButton().controlSize(.large)
                        }
                    }.padding(.vertical, 18)
                    HealthDashboardTiles(
                        snapshot: snapshot,
                        storage: openStorageOverview,
                        memory: { resourceFocus = .memory },
                        cpu: { resourceFocus = .cpu }
                    )
                } else {
                    Text(L10n.text("새 관찰이 도착하면 현재 상태를 표시합니다. 이전 기록은 관찰 기록에서 확인할 수 있습니다."))
                        .foregroundStyle(.secondary)
                    Button(L10n.text("관찰 기록")) { showHistory = true }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(monitor.enabled ? L10n.text("상태를 읽고 있습니다") : L10n.text("관찰이 꺼져 있습니다"))
                    .foregroundStyle(.secondary)
                if monitor.enabled { ProgressView().controlSize(.small) }
                else { Button(L10n.text("관찰 켜기")) { Task { await monitor.setEnabled(true) } } }
            }
        }
    }

    private func processSection(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text(L10n.text("관찰 당시 자원을 쓰는 작업")).font(.title3.bold())
                Spacer()
                Text(L10n.text(resourceFocus == .cpu ? "CPU 사용량 순" : "메모리 사용량 순")).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
                ForEach((resourceFocus ?? .memory).sorted(snapshot.processes)) { process in
                    VStack(alignment:.leading,spacing:12) {
                        HStack(spacing:12) {
                            Image(systemName:process.name.contains("VirtualMachine") ? "server.rack" : "app").font(.title2).foregroundStyle(.teal)
                            Text(process.name.contains("VirtualMachine") ? L10n.text("가상머신") : process.name).font(.headline).lineLimit(1).help(process.name)
                            Spacer()
                        }
                        HStack(spacing:16) {
                            Label(processCPUText(process, snapshot: snapshot), systemImage: "cpu")
                            Label(processMemoryText(process), systemImage: "memorychip")
                        }.font(.callout.weight(.medium)).monospacedDigit()
                        if let app = NSRunningApplication(processIdentifier: process.pid), app.activationPolicy == .regular {
                            Button(L10n.text("앱 앞으로 가져오기")) {
                                if !app.isTerminated { _ = app.activate(options: [.activateIgnoringOtherApps]) }
                            }.buttonStyle(.bordered)
                        }
                        if let workspace=process.workspace {
                            HStack {
                                Label(URL(fileURLWithPath:workspace).lastPathComponent,systemImage:"folder").lineLimit(1).help(workspace)
                                Spacer()
                                let matches=matchingSessions(workspace)
                                if !matches.isEmpty {
                                    Button(L10n.format("경로 일치 대화 %@", String(describing: matches.count))) { model.sessionSearch=workspace;openWork() }.buttonStyle(.plain).foregroundStyle(.teal)
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        } else { Label(L10n.text("프로젝트 연결 미확인"),systemImage:"link").font(.caption).foregroundStyle(.secondary) }
                    }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                        .background(Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:16))
                        .contextMenu { Text("PID \(process.pid)"); Text(process.name); Text(process.workspace ?? L10n.text("작업 경로 미확인")) }
                }
            }
            Text(L10n.text("CPU 100% = 코어 1개 · 실제 점유 메모리를 우선 표시하며 지원하지 않으면 공유 영역을 포함한 상주 메모리를 표시합니다. 경로 일치는 실행한 세션의 확정 근거가 아닙니다.")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("발생 기록과 조치 후 변화")).font(.headline)
            ForEach(monitor.journal.incidents.prefix(10)) { incident in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(incident.issues.map(L10n.text).joined(separator: " · ")).fontWeight(.medium)
                        Text("\(incident.first.date.formatted()) · \(incident.interrupted ? L10n.text("감시 중단 · 회복 미확인") : (incident.resolvedAt == nil ? L10n.text("관찰 중") : L10n.text("60초간 경고 기준 아래")))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(incident.latest.change(from: incident.first))
                        if let action = incident.action, let baseline = incident.actionBaseline {
                            Text(L10n.format("%@ 이후: %@", String(describing: action), String(describing: incident.latest.change(from: baseline))))
                            Text(L10n.text("조치의 인과 효과가 아닌 관찰된 변화입니다.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
            if monitor.journal.incidents.isEmpty { Text(L10n.text("아직 기록된 경고 상황이 없습니다.")).foregroundStyle(.secondary) }
            RecoveryHistorySection()
        }
    }

    private func matchingSessions(_ workspace: String) -> [SessionIndexEntry] {
        (model.sessionIndex?.sessions ?? []).filter { $0.workspace == workspace }
    }

    private func processCPUText(_ process: HealthProcess, snapshot: HealthSnapshot) -> String {
        guard snapshot.cpuAvailable, process.cpuMeasured != false else { return L10n.text("측정 불가") }
        return "\(Int(process.cpu))%"
    }

    private func processMemoryText(_ process: HealthProcess) -> String {
        let bytes = (process.physicalFootprintBytes ?? process.residentBytes).map { Int64(clamping: $0) }
        return process.physicalFootprintBytes == nil
            ? L10n.format("상주 메모리 %@", HealthSnapshot.bytes(bytes))
            : L10n.format("실제 점유 메모리 %@", HealthSnapshot.bytes(bytes))
    }

    private func copyContext() {
        guard let snapshot = monitor.snapshot else { return }
        let incident = monitor.journal.incidents.first
        var lines = [L10n.format("Modore 관찰 %@", snapshot.date.formatted()), snapshot.summary]
        if hasCurrentSnapshot {
            lines.append(snapshot.explanation(from: incident?.first))
        } else {
            lines.append(L10n.text("마지막 관찰 · 현재 상태 미확인"))
        }
        lines += snapshot.processes.map { process in
            L10n.format("%@ PID %@: CPU %@ · %@ · 작업 경로 %@",
                        process.name, String(process.pid), processCPUText(process, snapshot: snapshot),
                        processMemoryText(process), process.workspace ?? L10n.text("미확인"))
        }
        if let incident { lines.append(L10n.format("최초 관찰 이후: %@", String(describing: snapshot.change(from: incident.first)))) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
    }
}
