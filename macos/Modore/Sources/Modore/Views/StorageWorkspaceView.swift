import SwiftUI

enum StorageWorkspaceSection: String, CaseIterable, Identifiable {
    case overview
    case cleanup
    case goal
    case result
    case development
    case applications
    case simulators

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L10n.text("사용 현황")
        case .cleanup: return L10n.text("정리 후보")
        case .goal: return L10n.text("공간 확보")
        case .result: return L10n.text("자동 정리 결과")
        case .development: return L10n.text("개발")
        case .applications: return L10n.text("앱")
        case .simulators: return L10n.text("시뮬레이터")
        }
    }
}

struct StorageWorkspacePage: View {
    @EnvironmentObject private var model: ScanModel
    @EnvironmentObject private var recovery: AutomaticCacheRecovery
    @Binding var section: StorageWorkspaceSection
    @State private var reviewPath: String?
    @State private var retirementOpen = false
    @State private var environmentRetirement = false
    @State private var buildArtifactsOpen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L10n.text("저장공간 작업"), selection: Binding(
                    get: { section == .overview ? StorageWorkspaceSection.overview : .goal },
                    set: { section = $0; reviewPath = nil }
                )) {
                    Text(L10n.text("사용 현황")).tag(StorageWorkspaceSection.overview)
                    Text(L10n.text("공간 비우기")).tag(StorageWorkspaceSection.goal)
                }.pickerStyle(.segmented).frame(width: 280)
                Spacer()
                Menu(L10n.text("환경·프로젝트 검토")) {
                    Button(L10n.text("실행 환경")) { environmentRetirement = true }
                    Button(L10n.text("프로젝트 정리")) { retirementOpen = true }
                    Button(L10n.text("빌드 산출물 보관·회수")) { buildArtifactsOpen = true }
                }.fixedSize()
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            if section == .result {
                VStack(alignment: .leading, spacing: 10) {
                    if let report = recovery.last {
                        let notice = ResourceNotice.automaticRecovery(report)
                        Text(notice.title).font(.title2.bold())
                        Text(L10n.format("기록 시각 %@ · 현재 공간은 상단 상태에서 확인하세요.", report.date.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(L10n.text("자동 정리 처리 내역")) { AutomaticRecoveryDetails(report: report) }
                    } else {
                        Text(L10n.text("자동 정리 기록을 찾지 못했습니다. 현재 정리 후보를 확인하세요."))
                    }
                    Button(L10n.text("남은 정리 후보 확인")) {
                        section = .goal
                        if model.storage == nil { model.prepareStorageReview() }
                    }.buttonStyle(.borderedProminent).disabled(model.isBusy)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if section == .overview {
                FullStorageBalanceView(onReviewCleanup: { path in reviewPath = path; section = .goal })
            } else if let storage = model.storage {
                SpaceGoalWorkspaceList(storage: storage, currentFreeGB: model.liveState.freeSpace?.value.freeGB,
                    initialFilter: resultFilter, initialQuery: reviewPath ?? "")
            } else {
                VStack(spacing: 16) {
                    ModernEmptyState(symbol: "internaldrive", title: L10n.text("정리할 항목을 확인하세요"),
                        message: L10n.text("경로와 크기, 사용 상태를 함께 확인합니다. 정리는 항목을 선택하고 승인한 뒤 실행됩니다."))
                    if model.isRunning {
                        ProgressView()
                        Button(L10n.text("확인 중지")) { model.cancelScan() }
                    } else {
                        Button(L10n.text("정리 후보 확인")) { model.prepareStorageReview() }
                            .buttonStyle(.borderedProminent).disabled(model.isBusy)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationDestination(isPresented: $environmentRetirement) { EnvironmentRetirementView() }
        .navigationDestination(isPresented: $retirementOpen) { AssetRetirementView() }
        .navigationDestination(isPresented: $buildArtifactsOpen) { BuildArtifactLifecycleView() }
    }

    private var resultFilter: StorageResultFilter {
        switch section {
        case .development: return .development
        case .applications: return .applications
        case .simulators: return .simulators
        default: return .all
        }
    }
}
