import AppKit
import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case cleanup
    case development
    case inventory
    case security
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "저장 공간"
        case .cleanup: return "공간 정리"
        case .development: return "개발 환경"
        case .inventory: return "앱 및 Simulator"
        case .security: return "보안 점검"
        case .activity: return "기록"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "internaldrive"
        case .cleanup: return "trash"
        case .development: return "hammer"
        case .inventory: return "square.grid.2x2"
        case .security: return "lock.shield"
        case .activity: return "clock"
        }
    }

    var tint: Color {
        .accentColor
    }

    var searchTerms: String {
        switch self {
        case .overview: return "요약 저장 공간 디스크 용량 변화"
        case .cleanup: return "공간 정리 캐시 삭제 회수"
        case .development: return "개발 환경 Xcode Android SDK runtime"
        case .inventory: return "앱 응용 프로그램 Simulator 시뮬레이터"
        case .security: return "보안 악성코드 자동실행 네트워크"
        case .activity: return "기록 로그 감시 이력"
        }
    }
}
struct ModernRootView: View {
    @EnvironmentObject private var model: ScanModel
    @State private var selection: AppDestination = .overview

    var body: some View {
        NavigationSplitView {
            ModernSidebar(selection: selection, onSelect: navigate)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
        } detail: {
            ModernDetailView(destination: selection, onNavigate: navigate)
                .navigationTitle(selection.title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            model.runScan()
                        } label: {
                            Image(systemName: model.isBusy ? "hourglass" : "arrow.clockwise")
                        }
                        .disabled(model.isBusy)
                        .help(model.isBusy ? "검사 중" : "지금 검사")

                        Menu {
                            Button("일반 리포트 열기") { model.openNormalReportInBrowser() }
                                .disabled(!model.hasNormalReport)
                            Button("공유용 리포트 열기") { model.openShareReportInBrowser() }
                                .disabled(!model.hasShareReport)
                            Divider()
                            Button("Finder에서 보기") { model.revealReportsInFinder() }
                                .disabled(!model.hasAnyReport)
                        } label: {
                            Image(systemName: "doc.text")
                        }
                        .menuIndicator(.hidden)
                        .help("리포트")
                    }
                }
        }
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
        guard destination != selection else { return }
        selection = destination
    }
}

struct ModernSidebar: View {
    @EnvironmentObject private var model: ScanModel
    let selection: AppDestination
    let onSelect: (AppDestination) -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: nativeSelection) {
                Section {
                    ForEach(filteredDestinations) { destination in
                        HStack(spacing: 10) {
                            Image(systemName: destination.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            Text(destination.title)
                        }
                        .tag(destination)
                    }
                }

            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "검색")
            .onChange(of: query) { newValue in
                let matches = matchingDestinations(for: newValue)
                let needle = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !needle.isEmpty, !matches.contains(selection) {
                    let target = matches.first(where: { $0 != .overview }) ?? matches.first
                    if let target {
                        onSelect(target)
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Image(systemName: model.state.symbol)
                    .foregroundStyle(model.state.color)
                VStack(alignment: .leading, spacing: 1) {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(sidebarStatusTitle)
                            .font(.caption.weight(.semibold))
                    }
                    if let storage = model.storage {
                        Text("\(storage.freeGB, specifier: "%.1f")GB 남음")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
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

    private var filteredDestinations: [AppDestination] {
        matchingDestinations(for: query)
    }

    private func matchingDestinations(for value: String) -> [AppDestination] {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return AppDestination.allCases }
        return AppDestination.allCases.filter {
            searchIndex(for: $0).localizedCaseInsensitiveContains(needle)
        }
    }

    private var sidebarStatusTitle: String {
        if model.isRunning || model.state == .failed {
            return model.state.title
        }
        return model.storageSnapshotAgeText
    }

    private func searchIndex(for destination: AppDestination) -> String {
        var values = [destination.title, destination.searchTerms]
        if let storage = model.storage {
            switch destination {
            case .overview:
                values += storage.cleanupCandidates.map(\.label)
                values += storage.developerToolchains.map(\.label)
                values += storage.applications.map(\.label)
                values += storage.simulatorDevices.map(\.name)
            case .cleanup:
                values += (storage.cleanupCandidates + storage.reviewCandidates).flatMap {
                    [$0.label, $0.note, $0.path]
                }
            case .development:
                values += storage.developerToolchains.flatMap { [$0.label, $0.note, $0.path] }
                values += storage.runtimeSignals.flatMap { [$0.label, $0.note] }
            case .inventory:
                values += storage.applications.flatMap { [$0.label, $0.path] }
                values += storage.simulatorDevices.flatMap { [$0.name, $0.runtime] }
            case .security:
                values += storage.accessIssues.flatMap { [$0.label, $0.path, $0.note] }
                values += model.findings.flatMap { [$0.title, $0.detail] }
                values += model.autorunRows.flatMap { [$0.entry, $0.image] }
                values += model.recentInstalls.flatMap { [$0.name, $0.publisher] }
            case .activity:
                values.append(model.logText)
            }
        }
        return values.joined(separator: " ")
    }
}

struct SidebarDestinationRow: View {
    let destination: AppDestination
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIcon(symbol: destination.symbol, tint: destination.tint, size: 26)
                Text(destination.title)
                    .font(.body.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

struct ModernDetailView: View {
    let destination: AppDestination
    let onNavigate: (AppDestination) -> Void

    var body: some View {
        switch destination {
        case .overview:
            SettingsStorageOverviewPage(onNavigate: onNavigate)
        case .cleanup:
            CleanupPage()
        case .development:
            DevelopmentPage()
        case .inventory:
            InventoryPage()
        case .security:
            SecurityPage()
        case .activity:
            ActivityPage()
        }
    }
}
