import ModoreDomain
import SwiftUI

struct SpaceGoalWorkspaceList: View {
    @EnvironmentObject private var model: ScanModel
    let storage: StorageSnapshot
    let currentFreeGB: Double?
    @State private var targetBytes: Int64
    @State private var excludedCandidates: Set<String> = []

    init(storage: StorageSnapshot, currentFreeGB: Double? = nil) {
        self.storage = storage
        self.currentFreeGB = currentFreeGB
        let gap = StorageRecoveryPolicy.default.requiredGainBytes(
            currentAvailableBytes: StorageBytes.fromLegacyGiB(currentFreeGB ?? storage.freeGB) ?? 0
        )
        let goal = gap > 0 ? Double(gap) / Double(StorageBytes.perGiB) : 5
        _targetBytes = State(initialValue: StorageBytes.fromLegacyGiB(max(1, goal.rounded(.up))) ?? StorageBytes.perGiB)
    }

    private var candidates: [StorageItem] {
        SpaceGoalSelection.reviewCandidates(storage.recoveryCandidates)
    }

    private var selection: [StorageItem] {
        candidates.filter { !excludedCandidates.contains(SpaceGoalSelection.key($0)) }
    }

    private var pendingCount: Int {
        candidates.filter { $0.measureStatus == "timed_out" }.count
    }

    private var freeBytes: Int64? {
        StorageBytes.fromLegacyGiB(currentFreeGB ?? storage.freeGB)
    }

    private var targetGB: Double { Double(targetBytes) / Double(StorageBytes.perGiB) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if candidates.isEmpty {
                VStack(spacing: 16) {
                    ModernEmptyState(
                        symbol: "checkmark.circle",
                        title: L10n.text("정리 가능한 항목이 없습니다"),
                        message: L10n.text("다시 검사하거나 왼쪽에서 실행 환경과 프로젝트를 확인하세요.")
                    )
                    Button(L10n.text("다시 검사")) { model.runScan() }
                        .disabled(model.isBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                candidateList
                Divider()
                actionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("공간 확보"))
                    .font(.system(size: 28, weight: .bold))
                Text(L10n.text("항목을 고르면 크기와 사용 여부를 확인합니다. 삭제는 다음 화면에서 승인합니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("현재 여유 공간"))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(StorageBytes.text(freeBytes))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(currentFreeGB == nil ? L10n.text("마지막 검사 기준") : L10n.text("실시간 확인"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("추가로 확보할 공간"))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text(StorageBytes.text(targetBytes))
                            .font(.title2.weight(.semibold)).monospacedDigit()
                        Stepper(L10n.text("추가 확보 목표"), value: Binding(
                            get: { targetGB },
                            set: { targetBytes = StorageBytes.fromLegacyGiB($0) ?? targetBytes }
                        ), in: 1...max(2, storage.totalGB.rounded(.up), targetGB), step: 1)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.isBusy)
                        .accessibilityValue(StorageBytes.text(targetBytes))
                    }
                    Text(L10n.text("실제 확보량은 정리 후 확인합니다"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(24)
    }

    private var candidateList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle(L10n.text("모두 선택"), isOn: Binding(
                    get: { selection.count == candidates.count },
                    set: { all in
                        excludedCandidates = all ? [] : Set(candidates.map(SpaceGoalSelection.key))
                    }
                ))
                .toggleStyle(.checkbox)
                .disabled(model.isBusy)
                Spacer()
                Text(L10n.format("정리 후보 %@개", String(candidates.count)))
                    .fontWeight(.medium)
                if pendingCount > 0 {
                    Text(L10n.format("%@개 크기 확인 필요", String(pendingCount)))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach([CleanupTier.safe, .rebuild], id: \.rawValue) { tier in
                        let items = candidates.filter { $0.cleanupTier == tier }
                        if !items.isEmpty {
                            Text(tier.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 14).padding(.bottom, 8)
                            ForEach(items) { item in
                                SpaceGoalCandidateRow(item: item, isSelected: Binding(
                                    get: { !excludedCandidates.contains(SpaceGoalSelection.key(item)) },
                                    set: { selected in
                                        let key = SpaceGoalSelection.key(item)
                                        if selected { excludedCandidates.remove(key) }
                                        else { excludedCandidates.insert(key) }
                                    }
                                ))
                                .disabled(model.isBusy)
                                Divider()
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = model.cleanupRecoveryProgress, model.cleanupRecoveryPlan == nil {
                HStack(spacing: 14) {
                    ProgressView(value: progress.fraction).frame(maxWidth: 220)
                    Text(L10n.format("항목 확인 중 %@ / %@", String(progress.completedCount), String(progress.totalCount)))
                        .font(.callout).monospacedDigit()
                    Spacer()
                    Button(L10n.text("확인 취소")) { model.cancelCleanupPreviewRequest() }
                        .disabled(model.cleanupIsExecuting)
                }
            } else {
                HStack(spacing: 16) {
                    Text(L10n.format("%@개 선택됨", String(selection.count)))
                        .font(.callout.weight(.medium)).monospacedDigit()
                    Spacer()
                    Button {
                        model.prepareRecoveryPlan(selection, requestedGainBytes: targetBytes)
                    } label: {
                        Text(L10n.text("선택한 항목 확인"))
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy || selection.isEmpty)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
}
