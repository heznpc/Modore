import SwiftUI

struct QuotaWorkCard: View {
    @EnvironmentObject private var model: QuotaWorkModel
    let snapshot: QuotaWorkSnapshot
    let task: QuotaWorkSnapshot.Task

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let current = snapshot.isCurrent(now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                Text("QuotaPie · \(current ? task.statusText : L10n.text("작업 상태가 오래되었습니다"))")
                    .font(.callout.weight(.medium))
                if let account = snapshot.accounts.first(where: { $0.provider == task.provider && $0.account == task.account }) {
                    Text("\(task.provider.capitalized) · \(account.label)").font(.caption)
                    if current, account.collectionState == "recent-success",
                       let window = account.windows.first(where: { $0.bucket == task.bucket }),
                       window.freshness == "fresh", window.validUntilMs > context.date.timeIntervalSince1970 * 1_000,
                       let remaining = window.remainingPercent {
                        Text("\(window.label) · \(L10n.format("%@ 남음", String(format: "%.0f%%", remaining)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(L10n.text("QuotaPie에서 이어가기 확인")) { model.review(task) }
                    .disabled(!current)
                    .accessibilityIdentifier("quota-work-review")
                Text(L10n.text("재개할 때 QuotaPie가 한도와 세션을 다시 확인하고 승인을 요청합니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
