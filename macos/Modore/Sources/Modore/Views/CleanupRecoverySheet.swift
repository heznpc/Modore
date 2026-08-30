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
                    Text("공간 확보 계획")
                        .font(.title2.weight(.semibold))
                    Text(plan.canExecute
                        ? "실행 준비된 경로를 한 번 승인하면 목표에 도달할 때까지 순서대로 정리합니다."
                        : "실행할 수 없는 항목이 있어 계획을 다시 확인해야 합니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(plan.estimatedText)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("재측정한 대상 점유")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 18) {
                recoveryMetric("현재 여유", value: Self.gbText(plan.baselineFreeGB))
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                recoveryMetric("목표 여유", value: Self.gbText(plan.desiredFreeGB))
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
                    Label("AI 호출 없음 · 서명된 로컬 레시피", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("취소", role: .cancel) { model.dismissRecoveryPlan() }
                        .disabled(model.cleanupInFlight)
                        .keyboardShortcut(.cancelAction)
                    if plan.canExecute(at: timeline.date) {
                        if !plan.blockedEntries.isEmpty {
                            Button("전체 다시 측정") { model.retryRecoveryPlan(plan) }
                                .disabled(model.cleanupInFlight)
                        }
                        Button(role: .destructive) {
                            model.executeRecoveryPlan(plan)
                        } label: {
                            Label("\(plan.readyEntries.count)개 계획 실행", systemImage: "trash")
                        }
                        .disabled(model.cleanupInFlight)
                        .tint(.red)
                    } else {
                        Button("승인 다시 측정") { model.retryRecoveryPlan(plan) }
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
                Text(result.goalMet ? "공간 확보 목표 달성" : "공간 확보 결과")
                    .font(.title2.weight(.semibold))
                Text(!result.freeSpaceMeasured
                    ? "실제 여유 공간을 확인하지 못해 목표 달성을 판정하지 않았습니다."
                    : (result.stoppedAfterFailure
                        ? "한 항목의 안전 검증이 실패해 남은 계획을 중단했습니다."
                        : "실제 파일 시스템 여유 공간을 다시 읽어 확인했습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        HStack(spacing: 22) {
            recoveryMetric(
                "실제 증가",
                value: result.freeSpaceMeasured ? "+" + Self.gbText(result.actualGainGB) : "확인 실패"
            )
            recoveryMetric(
                "현재 여유",
                value: result.freeSpaceMeasured ? Self.gbText(result.finalFreeGB) : "확인 실패"
            )
            recoveryMetric("완료", value: "\(result.succeededCount)개")
            if result.skippedCount > 0 {
                recoveryMetric(
                    result.stoppedAfterFailure ? "안전 검증 실패로 미실행" : "목표 도달로 생략",
                    value: "\(result.skippedCount)개"
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
                                ? "처리 대상 \(Self.kbText(item.reclaimedKB)) · 실행 중 실제 여유 변화 \(Self.kbText(item.physicalDeltaKB))"
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
                    Label("후보 목록은 백그라운드 정밀 검사로 한 번 갱신합니다.", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider()
        HStack {
            Text("목표 \(Self.gbText(result.desiredFreeGB))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !result.goalMet {
                Button("남은 후보 다시 측정") { model.retryRecoveryPlan(plan) }
                    .disabled(model.cleanupInFlight)
            }
            Button("닫기") { model.dismissRecoveryPlan() }
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

    private static func gbText(_ value: Double) -> String {
        String(format: "%.1fGB", max(0, value))
    }

    private static func kbText(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value) * 1_024, countStyle: .file)
    }
}

private struct CleanupPlanEntryView: View {
    let entry: CleanupPlanEntry

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                if !entry.preview.summary.isEmpty {
                    Text(entry.preview.summary)
                }
                if !entry.preview.warning.isEmpty {
                    Label(entry.preview.warning, systemImage: "arrow.triangle.2.circlepath")
                }
                ForEach(entry.preview.targets, id: \.self) { target in
                    Text(target)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if !entry.preview.blockedReason.isEmpty {
                    Label(entry.preview.blockedReason, systemImage: "pause.circle")
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
                    Text(entry.tier.title)
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
        ByteCountFormatter.string(fromByteCount: max(0, estimatedKB) * 1_024, countStyle: .file)
    }
}
