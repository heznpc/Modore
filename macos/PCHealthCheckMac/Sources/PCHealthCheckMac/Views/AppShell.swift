import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case status
    case storage
    case security
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "상태"
        case .storage: return "저장공간"
        case .security: return "보안"
        case .activity: return "활동"
        }
    }

    var symbol: String {
        switch self {
        case .status: return "checkmark.circle"
        case .storage: return "internaldrive"
        case .security: return "lock.shield"
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
            ModernDetailView(
                destination: selection,
                storageSection: $storageSection,
                onOpenStorage: openStorage,
                onNavigate: navigate
            )
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
        .alert(
            "PC Health Check",
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
        if model.isRunning { return "검사 취소" }
        if model.storageWatchInFlight { return "설정 적용 중" }
        return "지금 검사"
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
        if model.isRunning { return "현재 검사를 안전하게 중단합니다" }
        if model.storageWatchInFlight { return "감시 설정을 적용하고 있습니다" }
        return "현재 상태 다시 검사"
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
                }
            }
        } icon: {
            Image(systemName: destination.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    destination == .security && model.securityHasDanger
                        ? Color.red
                        : Color.secondary
                )
        }
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
                if let storage = model.storage {
                    Text("\(storage.freeGB, specifier: "%.1f")GB 사용 가능")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func statusTitle(at date: Date) -> String {
        if model.isRunning { return "검사 중" }
        if model.cleanupInFlight { return "정리 대상 확인 중" }
        if model.storageWatchInFlight { return "감시 설정 적용 중" }
        if model.securityHasDanger {
            return model.securityAttentionCount > 0
                ? "위험 신호 \(model.securityAttentionCount)건"
                : "위험 신호 확인"
        }
        if model.storageSnapshotNeedsRefresh(at: date) { return "업데이트 필요" }
        if model.securityAttentionCount > 0 { return "확인 항목 \(model.securityAttentionCount)건" }
        return model.storageSnapshotAgeText
    }

    private func statusSymbol(at date: Date) -> String {
        if model.securityHasDanger { return "exclamationmark.shield" }
        if model.storageSnapshotNeedsRefresh(at: date) { return "clock" }
        if model.securityAttentionCount > 0 { return "info.circle" }
        return model.state.symbol
    }

    private var statusColor: Color {
        model.state == .failed || model.securityHasDanger ? .red : .secondary
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
        case .activity:
            ActivityPage()
        }
    }
}
