import SwiftUI

/// The health landing page follows one task: identify a problem, review a safe action, verify its result.
struct HealthWorkflowActions: View {
    let diagnose: () -> Void
    let review: () -> Void
    let results: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("도구")).font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { tools }
                VStack(spacing: 12) { tools }
            }
        }
    }

    @ViewBuilder private var tools: some View {
        HealthActionTile(title: L10n.text("앱 진단"), subtitle: L10n.text("문제 확인"), icon: "app.badge", action: diagnose)
        HealthActionTile(title: L10n.text("점검과 조치"), subtitle: L10n.text("조치 검토"), icon: "checklist", action: review)
        HealthActionTile(title: L10n.text("결과와 기록"), subtitle: L10n.text("결과 확인"), icon: "clock.arrow.circlepath", action: results)
    }
}
