import SwiftUI

struct CleanupRecoverySheet: View {
    @EnvironmentObject private var model: ScanModel
    let initialPlan: CleanupRecoveryPlan

    private var plan: CleanupRecoveryPlan {
        model.cleanupRecoveryPlan ?? initialPlan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let result = model.cleanupRecoveryResult {
                resultContent(result)
            } else {
                reviewContent
            }
            if let error = model.recoveryHistoryError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(
            minWidth: 600,
            idealWidth: 700,
            maxWidth: 820,
            minHeight: 420,
            idealHeight: 560,
            maxHeight: 720
        )
        .interactiveDismissDisabled(model.cleanupInFlight)
    }

    private var reviewContent: some View {
        Group {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: plan.canExecute ? "checklist" : "pause.circle")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("공간 확보 계획"))
                        .font(.title2.weight(.semibold))
                    Text(plan.canExecute
                        ? L10n.text("승인한 후보를 순서대로 정리하고 실제 여유 공간으로 중단 여부를 판단합니다. 모든 후보를 정리해도 목표에 못 미칠 수 있습니다.")
                        : (plan.readyEntries.isEmpty
                            ? L10n.text("이번에 확인된 실행 가능 항목이 없습니다. 항목별 이유를 확인하고 다시 시도하세요.")
                            : L10n.text("확인 후 시간이 지나 대상의 현재 상태를 다시 확인해야 합니다.")))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(L10n.text("실제 회수량 미확정"))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(L10n.format("파일 크기 합계 %@ · 공유 블록 포함 가능", String(describing: plan.estimatedText)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 18) {
                recoveryMetric(L10n.text("기준 여유"), value: StorageBytes.text(plan.baselineFreeBytes))
                recoveryMetric(L10n.text("추가 확보 목표"), value: StorageBytes.text(plan.requestedGainBytes))
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                recoveryMetric(L10n.text("최종 여유 목표"), value: StorageBytes.text(plan.desiredFreeBytes))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(plan.approvalStatusText(at: timeline.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.entries) { entry in
                        CleanupPlanEntryView(entry: entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }

            if let progress = model.cleanupRecoveryProgress, model.cleanupInFlight {
                VStack(alignment: .leading, spacing: 7) {
                    ProgressView(value: progress.fraction)
                    Text("\(progress.currentLabel) · \(progress.completedCount)/\(progress.totalCount)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                HStack {
                    Text(L10n.text("사용 중이거나 미확인인 항목은 건너뜁니다"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("취소"), role: .cancel) { model.dismissRecoveryPlan() }
                        .disabled(model.cleanupInFlight)
                        .keyboardShortcut(.cancelAction)
                    if plan.canExecute(at: timeline.date) {
                        if !plan.blockedEntries.isEmpty {
                            Button(L10n.text("제외 항목만 재확인")) { model.retryRecoveryPlan(plan, onlyUnavailable: true) }
                                .disabled(model.cleanupInFlight)
                        }
                        Button(role: .destructive) {
                            model.executeRecoveryPlan(plan)
                        } label: {
                            Label(L10n.format("%@개 계획 실행", String(describing: plan.readyEntries.count)), systemImage: "trash")
                        }
                        .disabled(model.cleanupInFlight)
                        .tint(.red)
                    } else {
                        Button(L10n.text("승인 다시 측정")) { model.retryRecoveryPlan(plan) }
                            .disabled(model.cleanupInFlight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultContent(_ result: CleanupRecoveryResult) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: result.goalMet ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(result.goalMet ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.goalMet ? L10n.text("공간 확보 목표 달성") : L10n.text("목표 미달 · 추가 확보 필요"))
                    .font(.title2.weight(.semibold))
                Text(!result.freeSpaceMeasured
                    ? L10n.text("실제 여유 공간을 확인하지 못해 목표 달성을 판정하지 않았습니다.")
                    : (result.stoppedAfterFailure
                        ? L10n.text("한 항목의 안전 검증이 실패해 남은 계획을 중단했습니다.")
                        : L10n.text("실제 파일 시스템 여유 공간을 다시 읽어 확인했습니다.")))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        HStack(spacing: 22) {
            recoveryMetric(
                L10n.text("여유 공간 순변화"),
                value: StorageBytes.changeText(result.actualChangeBytes)
            )
            recoveryMetric(
                L10n.text("현재 여유"),
                value: StorageBytes.text(result.finalFreeBytes)
            )
            recoveryMetric(L10n.text("완료"), value: L10n.format("%@개", String(describing: result.succeededCount)))
            if result.skippedCount > 0 {
                recoveryMetric(
                    result.stoppedAfterFailure ? L10n.text("안전 검증 실패로 미실행") : L10n.text("목표 도달로 생략"),
                    value: L10n.format("%@개", String(describing: result.skippedCount))
                )
            }
            Spacer()
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(result.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.succeeded ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(item.succeeded ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.label).font(.body.weight(.medium))
                            Text(item.succeeded
                                ? L10n.format("대상 점유 감소 %@ · 여유 공간 순변화 %@", String(describing: StorageBytes.text(item.reclaimedBytes)), String(describing: StorageBytes.changeText(item.physicalDeltaBytes)))
                                : item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !item.receipt.isEmpty {
                                Text(item.receipt)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                    }
                }
                if result.rescanScheduled {
                    Label(L10n.text("후보 목록은 백그라운드 정밀 검사로 한 번 갱신합니다."), systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider()
        HStack {
            Text(L10n.format("추가 확보 목표 %@ · 최종 여유 목표 %@\n공간 순변화에는 다른 앱의 활동도 포함됩니다.", String(describing: StorageBytes.text(result.desiredFreeBytes - result.baselineFreeBytes)), String(describing: StorageBytes.text(result.desiredFreeBytes))))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !result.goalMet {
                Button(L10n.text("남은 후보 다시 측정")) { model.retryRecoveryPlan(plan) }
                    .disabled(model.cleanupInFlight)
            }
            Button(L10n.text("닫기")) { model.dismissRecoveryPlan() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func recoveryMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
        }
    }

}

private struct CleanupPlanEntryView: View {
    let entry: CleanupPlanEntry

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                if !entry.preview.summary.isEmpty {
                    Text(L10n.message(entry.preview.summary))
                }
                if !entry.preview.warning.isEmpty {
                    Label(L10n.message(entry.preview.warning), systemImage: "arrow.triangle.2.circlepath")
                }
                if !entry.preview.reviewResidue.isEmpty {
                    Text(L10n.format("사용 중이거나 미확인인 경로 %@개는 보존합니다.", String(describing: entry.preview.reviewResidue.count)))
                }
                ForEach(entry.preview.targets, id: \.self) { target in
                    Text(target)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if !entry.preview.blockedReason.isEmpty {
                    Label(L10n.message(entry.preview.blockedReason), systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.preview.label)
                        .font(.body.weight(.medium))
                    Text(entry.preview.blockedReason.isEmpty ? entry.tier.title : entry.preview.blockedReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.preview.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.preview.estimatedText)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .frame(minWidth: 78, alignment: .trailing)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension CleanupRecoveryPlan {
    var estimatedText: String {
        StorageBytes.text(estimatedBytes)
    }
}
