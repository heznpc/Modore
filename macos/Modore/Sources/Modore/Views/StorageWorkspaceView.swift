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
    @State private var reviewPath: String?
    @State private var retirementOpen = false
    @State private var environmentRetirement = false
    @State private var buildArtifactsOpen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("저장공간 작업", selection: Binding(
                    get: { section == .overview ? StorageWorkspaceSection.overview : .goal },
                    set: { section = $0; reviewPath = nil }
                )) {
                    Text("전체 사용 현황").tag(StorageWorkspaceSection.overview)
                    Text("조사·정리").tag(StorageWorkspaceSection.goal)
                }.pickerStyle(.segmented).frame(width: 280)
                Spacer()
                Menu("환경·프로젝트 검토") {
                    Button("실행 환경") { environmentRetirement = true }
                    Button("프로젝트 정리") { retirementOpen = true }
                    Button(L10n.text("빌드 산출물 보관·회수")) { buildArtifactsOpen = true }
                }.fixedSize()
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            if section == .overview {
                FullStorageBalanceView(onReviewCleanup: { path in reviewPath = path; section = .goal })
            } else if let storage = model.storage {
                SpaceGoalWorkspaceList(storage: storage, currentFreeGB: model.liveState.freeSpace?.value.freeGB,
                    initialFilter: resultFilter, initialQuery: reviewPath ?? "")
            } else {
                VStack(spacing: 16) {
                    ModernEmptyState(symbol: "internaldrive", title: "조사할 경로를 먼저 찾습니다",
                        message: "로컬 검사로 후보를 발견한 뒤 크기와 사용 근거를 조사합니다.")
                    if model.isRunning { ProgressView() }
                    else { Button("경로 목록 검사") { model.runScan() }.buttonStyle(.borderedProminent).disabled(model.isBusy) }
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
