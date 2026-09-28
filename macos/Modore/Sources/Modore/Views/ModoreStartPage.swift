import SwiftUI

/// Entry points describe the user's goal; system inventories stay in their own destinations.
struct ModoreStartPage: View {
    let onNavigate: (AppDestination) -> Void
    let onOpenStorage: (StorageWorkspaceSection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("무엇을 해결할까요?").font(.largeTitle.bold())
                    Text("할 일을 고르면 필요한 확인부터 안내합니다.")
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    goal("앱이 버벅여요", detail: "앱 선택 → 평소처럼 사용 → 부하와 동작 전후 결과 확인", symbol: "cursorarrow.motionlines", action: { onNavigate(.appDiagnostic) })
                    goal("저장공간을 비우고 싶어요", detail: "현재 공간과 정리 대상을 확인하고 확보 계획 만들기", symbol: "internaldrive", action: { onOpenStorage(.goal) })
                    goal("프로젝트·대화를 이어가고 싶어요", detail: "작업 폴더와 AI 대화 기록을 찾아 다시 열기", symbol: "folder", action: { onNavigate(.work) })
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Mac 전체 상태가 궁금하다면").font(.headline)
                        Text("현재 자원 상태를 보거나 전체 문제 점검을 진행하세요.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Mac 상태 보기") { onNavigate(.health) }
                }
                Button("전체 문제 점검") { onNavigate(.status) }
                    .buttonStyle(.link)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func goal(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
