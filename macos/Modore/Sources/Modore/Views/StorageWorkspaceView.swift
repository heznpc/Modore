import SwiftUI

enum StorageWorkspaceSection: String, CaseIterable, Identifiable {
    case cleanup
    case development
    case applications
    case simulators

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanup: return "정리"
        case .development: return "개발"
        case .applications: return "앱"
        case .simulators: return "Simulator"
        }
    }
}

struct StorageWorkspacePage: View {
    @EnvironmentObject private var model: ScanModel
    @Binding var section: StorageWorkspaceSection

    var body: some View {
        Group {
            if let storage = model.storage {
                VStack(spacing: 0) {
                    StorageWorkspaceToolbar(section: $section, storage: storage)
                    Divider()
                    workspaceList(storage)
                }
            } else {
                ModernEmptyState(
                    symbol: "internaldrive",
                    title: "저장공간 정보가 없습니다",
                    message: "검사가 끝나면 정리 후보와 설치 자산이 여기에 표시됩니다."
                )
            }
        }
    }

    @ViewBuilder
    private func workspaceList(_ storage: StorageSnapshot) -> some View {
        switch section {
        case .cleanup: CleanupWorkspaceList(storage: storage)
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
            Picker("저장공간 분류", selection: $section) {
                ForEach(StorageWorkspaceSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)

            HStack {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(model.storageSnapshotNeedsRefresh(at: context.date)
                        ? "검사 당시 \(value) · 업데이트 필요"
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
        case .cleanup: return "실행 가능한 대상의 점유 추정이며 미리보기에서 다시 측정합니다."
        case .development: return "빌드 도구와 실행 중인 생성원을 구분해 보여줍니다."
        case .applications: return "앱 본체와 정확히 귀속되는 사용자 데이터만 검토합니다."
        case .simulators: return "보존한 기기와 실행 중인 기기는 삭제하지 않습니다."
        }
    }

    private var value: String {
        switch section {
        case .cleanup: return storage.reclaimableText
        case .development: return storage.developerText
        case .applications: return storage.applicationsText
        case .simulators: return storage.simulatorText
        }
    }
}
