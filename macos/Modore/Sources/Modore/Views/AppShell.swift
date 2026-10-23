import ModoreDomain
import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case start
    case health
    case appDiagnostic
    case status
    case macRecheck
    case storage
    case security
    case work
    case activity
    case skills

    var id: String { rawValue }

    static let sidebarDestinations: [AppDestination] = [.health, .storage, .work]

    /// Secondary tools stay inside the user's task rather than becoming peer destinations.
    var topLevel: AppDestination {
        switch self {
        case .storage: return .storage
        case .work, .skills: return .work
        default: return .health
        }
    }

    var title: String {
        switch self {
        case .start: return L10n.text("시작")
        case .health: return L10n.text("Mac 상태")
        case .appDiagnostic: return L10n.text("앱 버벅임 진단")
        case .status: return L10n.text("문제 점검")
        case .macRecheck: return L10n.text("Mac 재점검")
        case .storage: return L10n.text("저장공간")
        case .security: return L10n.text("권한·자동 실행 점검")
        // Not "AI 세션": the object here is a project, and sessions are
        // one of the things it has. The old name also stopped being true
        // -- worktrees, git state and lineage arrived first on that
        // screen long before any session did.
        case .work: return L10n.text("개발 작업")
        case .skills: return L10n.text("AI 스킬")
        case .activity: return L10n.text("조치 기록")
        }
    }

    var symbol: String {
        switch self {
        case .start: return "house"
        case .health: return "macbook"
        case .appDiagnostic: return "cursorarrow.motionlines"
        case .status: return "waveform.path.ecg"
        case .macRecheck: return "list.bullet.clipboard"
        case .storage: return "internaldrive"
        case .security: return "lock.shield"
        case .work: return "folder.badge.gearshape"
        case .skills: return "books.vertical"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

struct ModernRootView: View {
    @EnvironmentObject private var ci: CIWatchService
    @EnvironmentObject private var model: ScanModel
    @EnvironmentObject private var monitor: CPUWatchService
    @EnvironmentObject private var quotaWork: QuotaWorkModel
    @State private var selection: AppDestination = .health
    @State private var storageSection: StorageWorkspaceSection = .overview
    @State private var healthResourceFocus: HealthResourceFocus?
    @State private var navigationPath = NavigationPath()
    @State private var betaCue = false
    @State private var buildInfo = false
    @StateObject private var skillService = SkillInventoryService()
    @StateObject private var skillState = SkillInventoryViewState()

    var body: some View {
        NavigationSplitView {
            ModernSidebar(selection: selection, onSelect: navigate)
                .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 260)
        } detail: {
          NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if selection != .macRecheck,
                       let freeSpace = model.liveState.currentFreeSpace(at: context.date),
                       freeSpace.value.pressure.needsRecovery,
                       !(selection == .storage && storageSection == .goal) {
                        StoragePressureBanner(
                            freeSpace: freeSpace.value,
                            openRecovery: openStorageRecovery
                        )
                        Divider()
                    }
                }

                ModernDetailView(
                    destination: selection,
                    storageSection: $storageSection,
                    healthResourceFocus: $healthResourceFocus,
                    skillService: skillService,
                    skillState: skillState,
                    onOpenStorage: openStorage,
                    onNavigate: navigate
                )
            }
            .navigationTitle(selection.title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if selection.topLevel == .work {
                        Menu {
                            Button(L10n.text("프로젝트·대화")) { navigate(to: .work) }
                            Button(L10n.text("AI 스킬")) { navigate(to: .skills) }
                        } label: { Label(L10n.text("개발 작업"), systemImage: "square.grid.2x2") }
                    } else if selection != selection.topLevel && selection != .start {
                        Button { navigate(to: selection.topLevel) } label: {
                            Label(L10n.text("Mac 상태로 돌아가기"), systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button { buildInfo = true } label: { Label(L10n.text("빌드 정보"), systemImage: "info.circle") }
                        .help(L10n.text("실행 중인 앱의 빌드 정보"))
                }
                if [.status, .security].contains(selection) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            performPrimaryAction()
                        } label: {
                            Label(primaryActionTitle, systemImage: primaryActionSymbol)
                            .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .disabled(primaryActionDisabled)
                        .help(primaryActionHelp)
                    }
                }
            }
          }
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL(perform: openURL)
        .sheet(isPresented: $betaCue) { BetaCueView() }
        .sheet(isPresented: $buildInfo) { ModoreBuildInfo() }
        .onChange(of: monitor.showHealth) { value in
            if value { navigate(to: .health); monitor.showHealth = false }
        }
        .alert(
            "Modore",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(L10n.text("확인"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func navigate(to destination: AppDestination) {
        navigationPath = NavigationPath()
        healthResourceFocus = nil
        selection = destination == .start ? .health : destination
    }

    private func openStorage(_ section: StorageWorkspaceSection) {
        storageSection = section
        navigate(to: .storage)
    }

    private func openStorageRecovery() {
        apply(.storageRecovery)
    }

    private func openURL(_ url: URL) {
        guard let route = ModoreRoute(url: url) else { return }
        apply(route)
    }

    private func apply(_ route: ModoreRoute) {
        switch route {
        case .betaCue:
            navigate(to: .work)
            betaCue = true
        case .ci:
            navigate(to: .work)
            ci.showIncidents = true
        case .quotaTask(let id):
            quotaWork.requestedSession = nil
            quotaWork.requestedTaskID = id
            quotaWork.message = nil
            navigate(to: .work)
        case .session(let link):
            quotaWork.requestedTaskID = nil
            quotaWork.requestedSession = link
            quotaWork.message = nil
            navigate(to: .work)
        case .health:
            navigate(to: .health)
        case .healthResources(let focus):
            navigate(to: .health)
            healthResourceFocus = focus
        case .storageRecoveryResult:
            openStorage(.result)
        case .storageRecovery:
            openStorage(.goal)
            if route.shouldStartStorageScan(
                hasStorageData: model.storage != nil,
                isBusy: model.isBusy
            ) {
                model.prepareStorageReview()
            }
        }
    }

    private func performPrimaryAction() {
        if model.isRunning {
            model.cancelScan()
        } else if model.cleanupInFlight, !model.cleanupIsExecuting {
            model.cancelCleanupPreviewRequest()
        } else {
            model.runScan()
        }
    }

    private var primaryActionTitle: String {
        if model.cleanupIsExecuting { return L10n.text("정리 중") }
        if model.cleanupInFlight { return L10n.text("미리보기 취소") }
        if model.isRunning { return L10n.text("정밀 검사 취소") }
        if model.storageWatchInFlight { return L10n.text("설정 적용 중") }
        return L10n.text("정밀 검사")
    }

    private var primaryActionSymbol: String {
        if model.cleanupIsExecuting || model.storageWatchInFlight { return "hourglass" }
        if model.cleanupInFlight || model.isRunning { return "xmark" }
        return "arrow.clockwise"
    }

    private var primaryActionDisabled: Bool {
        if model.cleanupIsExecuting { return true }
        if model.isRunning || model.cleanupInFlight { return false }
        return model.isBusy
    }

    private var primaryActionHelp: String {
        if model.cleanupIsExecuting { return L10n.text("승인한 정리가 끝날 때까지 중단하지 않습니다") }
        if model.cleanupInFlight { return L10n.text("삭제 없이 정리 대상 확인을 취소합니다") }
        if model.isRunning { return L10n.text("현재 정밀 검사를 안전하게 중단합니다") }
        if model.storageWatchInFlight { return L10n.text("감시 설정을 적용하고 있습니다") }
        return L10n.text("캐시·보안·자동 실행을 한 시점의 증거로 다시 평가합니다")
    }
}

private struct StoragePressureBanner: View {
    let freeSpace: LiveFreeSpace
    let openRecovery: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: freeSpace.pressure == .danger
                ? "exclamationmark.triangle.fill"
                : "internaldrive.fill")
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button(L10n.text("확보 계획 열기"), action: openRecovery)
                .buttonStyle(.borderedProminent)
                .tint(tint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(tint.opacity(0.09))
    }

    private var title: String {
        switch freeSpace.pressure {
        case .danger: return L10n.text("저장공간을 지금 확보해야 합니다")
        case .warning: return L10n.text("저장공간 확보를 권장합니다")
        case .normal: return L10n.text("저장공간이 충분합니다")
        }
    }

    private var detail: String {
        L10n.format("실제 여유 공간 %@. 정리할 항목을 확인해 공간을 확보하세요.", StorageBytes.text(freeSpace.freeBytes))
    }

    private var tint: Color {
        freeSpace.pressure == .danger ? .red : .secondary
    }
}

struct ModernSidebar: View {
    @EnvironmentObject private var model: ScanModel
    let selection: AppDestination
    let onSelect: (AppDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: nativeSelection) {
                ForEach(AppDestination.sidebarDestinations) { destination in
                    SidebarDestinationRow(destination: destination).tag(destination)
                }
            }
            .listStyle(.sidebar)

            Divider()
            SidebarScanStatus()
                .padding(12)
        }
    }

    private var nativeSelection: Binding<AppDestination?> {
        Binding(
            get: { selection.topLevel },
            set: { destination in
                if let destination {
                    onSelect(destination)
                }
            }
        )
    }
}

private struct SidebarDestinationRow: View {
    @EnvironmentObject private var model: ScanModel
    let destination: AppDestination

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            row(at: context.date)
        }
    }

    private func row(at date: Date) -> some View {
        Label {
            HStack {
                Text(destination.title)
                Spacer(minLength: 8)
                if destination == .health, model.securityAttentionCount > 0 {
                    Text("\(model.securityAttentionCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.securityHasDanger ? Color.red : Color.secondary)
                } else if destination == .storage,
                          let pressure = model.liveState.currentFreeSpace(at: date)?.value.pressure,
                          pressure.needsRecovery {
                    Text(pressure == .danger ? L10n.text("위험") : L10n.text("부족"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(storagePressureColor(pressure))
                }
            }
        } icon: {
            Image(systemName: destination.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(destinationColor(at: date))
        }
    }

    private func destinationColor(at date: Date) -> Color {
        if destination == .health, model.securityHasDanger { return .red }
        if destination == .storage,
           let pressure = model.liveState.currentFreeSpace(at: date)?.value.pressure,
           pressure.needsRecovery {
            return storagePressureColor(pressure)
        }
        return .secondary
    }

    private func storagePressureColor(_ pressure: StoragePressure) -> Color {
        pressure == .danger ? .red : .secondary
    }
}

private struct SidebarScanStatus: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            statusContent(at: context.date)
        }
    }

    private func statusContent(at date: Date) -> some View {
        HStack(spacing: 9) {
            Group {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: statusSymbol(at: date))
                        .foregroundStyle(statusColor(at: date))
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle(at: date))
                    .font(.caption.weight(.semibold))
                if let liveFreeSpace = model.liveState.currentFreeSpace(at: date) {
                    Text(L10n.format("실제 여유 공간 %@", StorageBytes.text(liveFreeSpace.value.freeBytes)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if let previous = model.liveState.freeSpace {
                    Text(L10n.format("마지막 관찰 %@", StorageBytes.text(previous.value.freeBytes)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help(previous.observedAt.formatted())
                } else if let storage = model.storage {
                    Text(L10n.format("검사 당시 %@", StorageBytes.text(StorageBytes.fromLegacyGiB(storage.freeGB))))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func statusTitle(at date: Date) -> String {
        if model.isRunning { return L10n.text("정밀 검사 중") }
        if model.storageMeasurementInFlight { return L10n.text("용량 측정 중") }
        if AppDiagnosticService.shared.active || AppDiagnosticService.shared.saving {
            return L10n.text("앱 버벅임 진단")
        }
        if model.cleanupIsExecuting {
            return model.cleanupRecoveryProgress.map {
                L10n.format("%@ 정리 중", String(describing: $0.currentLabel))
            } ?? L10n.text("정리 중")
        }
        if model.cleanupRecoveryProgress != nil { return L10n.text("공간 확보 계획 준비 중") }
        if model.cleanupInFlight { return L10n.text("정리 대상 확인 중") }
        if model.browserAutomationStopInFlight { return L10n.text("자동화 브라우저 확인 중") }
        if model.storageWatchInFlight { return L10n.text("감시 설정 적용 중") }
        if model.liveState.currentFreeSpace(at: date)?.value.pressure == .danger { return L10n.text("저장공간 즉시 확보 필요") }
        if model.state == .failed { return L10n.text("정밀 검사 실패") }
        if model.securityHasDanger {
            return model.securityAttentionCount > 0
                ? L10n.format("위험 신호 %@건", String(describing: model.securityAttentionCount))
                : L10n.text("위험 신호 확인")
        }
        if model.liveState.currentFreeSpace(at: date)?.value.pressure == .warning { return L10n.text("저장공간 확보 권장") }
        if model.summary == nil { return L10n.text("검사 기록 없음") }
        if model.collectionIsIncomplete { return L10n.text("안전 판단 보류") }
        if model.deepScanSnapshotNeedsRefresh(at: date) { return L10n.text("검사 결과 오래됨") }
        if model.securityAttentionCount > 0 { return L10n.format("확인 항목 %@건", String(describing: model.securityAttentionCount)) }
        return model.deepScanSnapshotAgeText
    }

    private func statusSymbol(at date: Date) -> String {
        if model.liveState.currentFreeSpace(at: date)?.value.pressure == .danger { return "exclamationmark.triangle.fill" }
        if model.securityHasDanger { return "exclamationmark.shield" }
        if model.state == .failed { return "exclamationmark.circle" }
        if model.liveState.currentFreeSpace(at: date)?.value.pressure == .warning { return "internaldrive.fill" }
        if model.summary == nil { return "questionmark.circle" }
        if model.collectionIsIncomplete { return "questionmark.shield" }
        if model.deepScanSnapshotNeedsRefresh(at: date) { return "clock" }
        if model.securityAttentionCount > 0 { return "info.circle" }
        return model.state.symbol
    }

    private func statusColor(at date: Date) -> Color {
        if model.liveState.currentFreeSpace(at: date)?.value.pressure == .danger { return .red }
        if model.state == .failed || model.securityHasDanger { return .red }
        if model.liveState.currentFreeSpace(at: date)?.value.pressure == .warning { return .secondary }
        return .secondary
    }
}

struct ModernDetailView: View {
    let destination: AppDestination
    @Binding var storageSection: StorageWorkspaceSection
    @Binding var healthResourceFocus: HealthResourceFocus?
    @ObservedObject var skillService: SkillInventoryService
    @ObservedObject var skillState: SkillInventoryViewState
    let onOpenStorage: (StorageWorkspaceSection) -> Void
    let onNavigate: (AppDestination) -> Void

    var body: some View {
        switch destination {
        case .appDiagnostic:
            AppDiagnosticPage()
        case .health, .start:
            HealthContextView(
                resourceFocus: $healthResourceFocus,
                openRecovery: { onOpenStorage(.goal) },
                openWork: { onNavigate(.work) },
                openStorageOverview: { onOpenStorage(.overview) },
                openDiagnosis: { onNavigate(.status) },
                openSecurity: { onNavigate(.security) },
                openRecheck: { onNavigate(.macRecheck) },
                openAppDiagnostic: { onNavigate(.appDiagnostic) },
                openActivity: { onNavigate(.activity) }
            )
        case .status:
            StatusPage(
                onOpenStorage: onOpenStorage,
                onOpenSecurity: { onNavigate(.security) },
                onOpenActivity: { onNavigate(.activity) },
                onOpenRecheck: { onNavigate(.macRecheck) }
            )
        case .macRecheck:
            MacRecheckPage(
                onOpenStorage: { onOpenStorage(.goal) },
                onOpenActivity: { onNavigate(.activity) },
                onOpenWork: { onNavigate(.work) }
            )
        case .storage:
            StorageWorkspacePage(section: $storageSection)
        case .security:
            SecurityPage()
        case .work:
            WorkPage()
        case .skills:
            SkillInventoryView(service: skillService, state: skillState)
        case .activity:
            VStack(spacing: 0) {
                HStack {
                    Label(L10n.text("앱 진단과 결과"), systemImage: "cursorarrow.motionlines")
                    Spacer()
                    Button(L10n.text("앱 진단에서 확인")) { onNavigate(.appDiagnostic) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider()
                ActivityPage()
            }
        }
    }
}
