import SwiftUI

/// The health landing page follows one task: identify a problem, review a safe action, verify its result.
struct HealthWorkflowActions: View {
    let diagnose: () -> Void
    let review: () -> Void
    let results: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("문제 해결")).font(.title2.bold())
            GroupBox {
                VStack(spacing: 0) {
                    step("1", title: L10n.text("문제 확인"), detail: L10n.text("느린 앱을 선택하고 평소처럼 사용하며 원인을 좁힙니다."), actionTitle: L10n.text("앱 진단"), action: diagnose)
                    Divider()
                    step("2", title: L10n.text("조치 검토"), detail: L10n.text("검사에서 확인한 항목을 보고 필요한 조치를 선택합니다."), actionTitle: L10n.text("점검과 조치"), action: review)
                    Divider()
                    step("3", title: L10n.text("결과 확인"), detail: L10n.text("실행 기록과 이후 관찰을 비교하고 남은 문제를 확인합니다."), actionTitle: L10n.text("결과와 기록"), action: results)
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func step(_ number: String, title: String, detail: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Text(number).font(.title3.weight(.semibold)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button(actionTitle, action: action).buttonStyle(.bordered)
        }
        .padding(.vertical, 14)
    }
}
