import SwiftUI

enum StorageWorkspaceSection: String, CaseIterable, Identifiable {
    case overview
    case cleanup
    case goal
    case development
    case applications
    case simulators

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L10n.text("사용 현황")
        case .cleanup: return L10n.text("정리 후보")
        case .goal: return L10n.text("공간 확보")
        case .development: return L10n.text("개발")
        case .applications: return L10n.text("앱")
        case .simulators: return L10n.text("시뮬레이터")
        }
    }
}

struct StorageWorkspacePage: View {
    @EnvironmentObject private var model: ScanModel
    @Binding var section: StorageWorkspaceSection
    @State private var retirementOpen = false
    @State private var environmentRetirement = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                if section == .overview {
                    FullStorageBalanceView()
                } else if let storage = model.storage {
                    VStack(spacing: 0) {
                        if section != .goal {
                            StorageWorkspaceToolbar(section: $section, storage: storage)
                        }
                        workspaceList(storage)
                    }
                } else {
                    VStack(spacing: 16) {
                        ModernEmptyState(
                            symbol: "internaldrive",
                            title: model.isRunning ? L10n.text("정리 후보를 측정하고 있습니다") : L10n.text("저장공간 정보가 없습니다"),
                            message: model.isRunning
                                ? L10n.text("검사가 끝나면 이 화면에 확보 계획이 바로 표시됩니다.")
                                : L10n.text("먼저 로컬 검사를 실행해 안전하게 정리할 수 있는 경로를 확인하세요.")
                        )
                        if model.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(L10n.text("정리 후보 측정")) { model.runScan() }
                                .buttonStyle(.borderedProminent).disabled(model.isBusy)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationDestination(isPresented: $environmentRetirement) { EnvironmentRetirementView() }
        .navigationDestination(isPresented: $retirementOpen) { AssetRetirementView() }
    }

    private var sidebar: some View {
        List(selection: Binding<StorageWorkspaceSection?>(
            get: { section },
            set: { if let value = $0 { section = value } }
        )) {
            Section(L10n.text("저장공간")) {
                ForEach(StorageWorkspaceSection.allCases) { item in
                    Label(item.title, systemImage: symbol(item)).tag(item)
                        .padding(.vertical, 3)
                }
            }
            Section(L10n.text("환경 정리")) {
                Button { environmentRetirement = true } label: {
                    Label(L10n.text("실행 환경"), systemImage: "desktopcomputer")
                }
                .buttonStyle(.plain).padding(.vertical, 3)
                Button { retirementOpen = true } label: {
                    Label(L10n.text("프로젝트 정리"), systemImage: "archivebox")
                }
                .buttonStyle(.plain).padding(.vertical, 3)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 180)
        .accessibilityLabel(L10n.text("저장공간 보기"))
    }

    private func symbol(_ section: StorageWorkspaceSection) -> String {
        switch section {
        case .overview: return "chart.pie"
        case .cleanup: return "tray.full"
        case .goal: return "sparkles"
        case .development: return "hammer"
        case .applications: return "app"
        case .simulators: return "iphone"
        }
    }

    @ViewBuilder
    private func workspaceList(_ storage: StorageSnapshot) -> some View {
        switch section {
        case .overview: FullStorageBalanceView()
        case .cleanup: CleanupWorkspaceList(storage: storage)
        case .goal: SpaceGoalWorkspaceList(
            storage: storage,
            currentFreeGB: model.liveState.freeSpace?.value.freeGB
        )
        case .development: DevelopmentWorkspaceList(storage: storage)
        case .applications: ApplicationWorkspaceList(storage: storage)
        case .simulators: SimulatorWorkspaceList(storage: storage)
        }
    }
}

private struct StorageWorkspaceToolbar: View {
    @EnvironmentObject private var model: ScanModel
    @Binding var section: StorageWorkspaceSection
    let storage: StorageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title).font(.title2.weight(.semibold))

            HStack {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(model.deepScanSnapshotNeedsRefresh(at: context.date)
                        ? L10n.format("정밀 검사 당시 %@ · 업데이트 필요", String(describing: value))
                        : value)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var summary: String {
        switch section {
        case .overview: return L10n.text("전체 사용량과 미측정 영역을 먼저 확인합니다.")
        case .cleanup: return L10n.text("실행 가능한 대상의 점유 추정이며 미리보기에서 다시 측정합니다.")
        case .goal: return L10n.text("정리 후보를 검토하고 실제 여유 공간으로 목표 달성을 확인합니다. 파일 크기는 회수량이 아닙니다.")
        case .development: return L10n.text("빌드 도구와 실행 중인 생성원을 구분해 보여줍니다.")
        case .applications: return L10n.text("앱 본체와 정확히 귀속되는 사용자 데이터만 검토합니다.")
        case .simulators: return L10n.text("기기 데이터, runtime 지원 자산과 공유 캐시를 중복 없이 함께 봅니다.")
        }
    }

    private var value: String {
        switch section {
        case .overview: return String(format: "%.1fGB", storage.totalGB)
        case .cleanup: return storage.reclaimableText
        case .goal: return storage.recoveryText
        case .development: return storage.developerText
        case .applications: return storage.applicationsText
        case .simulators:
            if storage.simulatorFootprintMeasurementIncomplete {
                return storage.simulatorFootprintGB > 0
                    ? String(format: L10n.text("최소 %.1fGB"), storage.simulatorFootprintGB)
                    : L10n.text("측정 보류")
            }
            return storage.simulatorFootprintText
        }
    }
}
