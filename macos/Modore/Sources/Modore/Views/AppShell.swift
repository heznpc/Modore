import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case status
    case storage
    case security
    case work
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "진단"
        case .storage: return "저장공간"
        case .security: return "보안"
        // Not "AI 세션": the object here is a project, and sessions are
        // one of the things it has. The old name also stopped being true
        // -- worktrees, git state and lineage arrived first on that
        // screen long before any session did.
        case .work: return "작업"
        case .activity: return "기록"
        }
    }

    var symbol: String {
        switch self {
        case .status: return "waveform.path.ecg"
        case .storage: return "internaldrive"
        case .security: return "lock.shield"
        case .work: return "folder.badge.gearshape"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

struct ModernRootView: View {
    @EnvironmentObject private var model: ScanModel
    @State private var selection: AppDestination = .status
    @State private var storageSection: StorageWorkspaceSection = .cleanup

    var body: some View {
        NavigationSplitView {
            ModernSidebar(selection: selection, onSelect: navigate)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if let freeSpace = model.liveState.freeSpace,
                   freeSpace.value.pressure.needsRecovery {
                    StoragePressureBanner(
                        freeSpace: freeSpace.value,
                        openRecovery: openStorageRecovery
                    )
                    Divider()
                }

                ModernDetailView(
                    destination: selection,
                    storageSection: $storageSection,
                    onOpenStorage: openStorage,
                    onNavigate: navigate
                )
            }
            .navigationTitle(selection.title)
            .toolbar {
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
        .navigationSplitViewStyle(.balanced)
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL(perform: openURL)
        .alert(
            "Modore",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func navigate(to destination: AppDestination) {
        selection = destination
    }

    private func openStorage(_ section: StorageWorkspaceSection) {
        storageSection = section
        selection = .storage
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
        case .storageRecovery:
            openStorage(.goal)
            if route.shouldStartStorageScan(
                hasStorageData: model.storage != nil,
                isBusy: model.isBusy
            ) {
                model.runScan()
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
        if model.cleanupIsExecuting { return "정리 중" }
        if model.cleanupInFlight { return "미리보기 취소" }
        if model.isRunning { return "정밀 검사 취소" }
        if model.storageWatchInFlight { return "설정 적용 중" }
        return "정밀 검사"
    }

    private var primaryActionSymbol: String {
        if model.cleanupIsExecuting || model.storageWatchInFlight { return "hourglass" }
        if model.cleanupInFlight || model.isRunning { return "xmark" }
        return "arrow.clockwise"
    }

    private var primaryActionDisabled: Bool {
        model.cleanupIsExecuting || model.storageWatchInFlight || model.resultLoading
    }

    private var primaryActionHelp: String {
        if model.cleanupIsExecuting { return "승인한 정리가 끝날 때까지 중단하지 않습니다" }
        if model.cleanupInFlight { return "삭제 없이 정리 대상 확인을 취소합니다" }
        if model.isRunning { return "현재 정밀 검사를 안전하게 중단합니다" }
        if model.storageWatchInFlight { return "감시 설정을 적용하고 있습니다" }
        return "캐시·보안·자동 실행을 한 시점의 증거로 다시 평가합니다"
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

            Button("확보 계획 열기", action: openRecovery)
                .buttonStyle(.borderedProminent)
                .tint(tint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(tint.opacity(0.09))
    }

    private var title: String {
        switch freeSpace.pressure {
        case .danger: return "저장공간을 지금 확보해야 합니다"
        case .warning: return "저장공간 확보를 권장합니다"
        case .normal: return "저장공간이 충분합니다"
        }
    }

    private var detail: String {
        String(
            format: "현재 %.1fGB 남았습니다. 정리 후보를 검토한 뒤 한 번 승인해 목표 용량을 확보할 수 있습니다.",
            freeSpace.freeGB
        )
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
                ForEach(AppDestination.allCases) { destination in
                    SidebarDestinationRow(destination: destination)
                        .tag(destination)
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
            get: { selection },
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
        Label {
            HStack {
                Text(destination.title)
                Spacer(minLength: 8)
                if destination == .security, model.securityAttentionCount > 0 {
                    Text("\(model.securityAttentionCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.securityHasDanger ? Color.red : Color.secondary)
                } else if destination == .storage,
                          let pressure = model.liveState.storagePressure,
                          pressure.needsRecovery {
                    Text(pressure == .danger ? "위험" : "부족")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(storagePressureColor(pressure))
                }
            }
        } icon: {
            Image(systemName: destination.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(destinationColor)
        }
    }

    private var destinationColor: Color {
        if destination == .security, model.securityHasDanger { return .red }
        if destination == .storage,
           let pressure = model.liveState.storagePressure,
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
        TimelineView(.periodic(from: .now, by: 60)) { context in
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
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle(at: date))
                    .font(.caption.weight(.semibold))
                if let liveFreeSpace = model.liveState.freeSpace {
                    Text("\(liveFreeSpace.value.freeGB, specifier: "%.1f")GB 사용 가능")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if let storage = model.storage {
                    Text("검사 당시 \(storage.freeGB, specifier: "%.1f")GB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func statusTitle(at date: Date) -> String {
        if model.isRunning { return "정밀 검사 중" }
        if model.cleanupIsExecuting {
            return model.cleanupRecoveryProgress.map {
                "\($0.currentLabel) 정리 중"
            } ?? "정리 중"
        }
        if model.cleanupRecoveryProgress != nil { return "공간 확보 계획 준비 중" }
        if model.cleanupInFlight { return "정리 대상 확인 중" }
        if model.browserAutomationStopInFlight { return "자동화 브라우저 확인 중" }
        if model.storageWatchInFlight { return "감시 설정 적용 중" }
        if model.liveState.storagePressure == .danger { return "저장공간 즉시 확보 필요" }
        if model.state == .failed { return "정밀 검사 실패" }
        if model.securityHasDanger {
            return model.securityAttentionCount > 0
                ? "위험 신호 \(model.securityAttentionCount)건"
                : "위험 신호 확인"
        }
        if model.liveState.storagePressure == .warning { return "저장공간 확보 권장" }
        if model.summary == nil { return "정밀 검사 필요" }
        if model.collectionIsIncomplete { return "안전 판단 보류" }
        if model.deepScanSnapshotNeedsRefresh(at: date) { return "정밀 검사 필요" }
        if model.securityAttentionCount > 0 { return "확인 항목 \(model.securityAttentionCount)건" }
        return model.deepScanSnapshotAgeText
    }

    private func statusSymbol(at date: Date) -> String {
        if model.liveState.storagePressure == .danger { return "exclamationmark.triangle.fill" }
        if model.securityHasDanger { return "exclamationmark.shield" }
        if model.state == .failed { return "exclamationmark.circle" }
        if model.liveState.storagePressure == .warning { return "internaldrive.fill" }
        if model.summary == nil { return "questionmark.circle" }
        if model.collectionIsIncomplete { return "questionmark.shield" }
        if model.deepScanSnapshotNeedsRefresh(at: date) { return "clock" }
        if model.securityAttentionCount > 0 { return "info.circle" }
        return model.state.symbol
    }

    private var statusColor: Color {
        if model.liveState.storagePressure == .danger { return .red }
        if model.state == .failed || model.securityHasDanger { return .red }
        if model.liveState.storagePressure == .warning { return .secondary }
        return .secondary
    }
}

struct ModernDetailView: View {
    let destination: AppDestination
    @Binding var storageSection: StorageWorkspaceSection
    let onOpenStorage: (StorageWorkspaceSection) -> Void
    let onNavigate: (AppDestination) -> Void

    var body: some View {
        switch destination {
        case .status:
            StatusPage(
                onOpenStorage: onOpenStorage,
                onOpenSecurity: { onNavigate(.security) },
                onOpenActivity: { onNavigate(.activity) }
            )
        case .storage:
            StorageWorkspacePage(section: $storageSection)
        case .security:
            SecurityPage()
        case .work:
            WorkPage()
        case .activity:
            ActivityPage()
        }
    }
}
