import ModoreDomain
import SwiftUI

/// Picks cache recipes before recipes that require a download or rebuild, then
/// takes the largest entries in each tier. Individual-only choices such as app
/// removal, models and simulators never enter a one-approval recovery plan.
enum SpaceGoalSelection {
    // Directory sizes can count shared APFS blocks repeatedly. They rank
    // review candidates but cannot establish that a free-space goal is met.
    static func reviewCandidates(_ candidates: [StorageItem]) -> [StorageItem] {
        select(from: candidates, targetBytes: Int64.max)
    }

    /// Sizes arrive rounded to a tenth of a GB, and a tenth is not exact in
    /// binary: four items truly summing to 3.0 add up to 2.9999999999999996,
    /// so a bare `>=` walked past the exact-match set and appended one more
    /// item than the goal needed, then reported the result as short of it.
    private static let goalTolerance = 0.000_001

    /// A timed-out scan still identifies a valid cleanup recipe, but its last
    /// reported size is not evidence we can use for planning. Keep the item as
    /// an unknown candidate so the preview can measure it again, while
    /// contributing zero until that fresh measurement succeeds.
    static func planningSizeGB(_ item: StorageItem) -> Double {
        Double(planningBytes(item)) / Double(StorageBytes.perGiB)
    }

    static func planningBytes(_ item: StorageItem) -> Int64 {
        guard item.measureStatus != "timed_out" else { return 0 }
        return StorageBytes.fromLegacyGiB(item.sizeGB) ?? 0
    }

    static func isPlanningCandidate(_ item: StorageItem) -> Bool {
        item.cleanupTier != nil
            && (item.measureStatus == "timed_out" || planningSizeGB(item) > 0)
    }

    static func select(from candidates: [StorageItem], targetGB: Double) -> [StorageItem] {
        select(from: candidates, targetBytes: StorageBytes.fromLegacyGiB(targetGB)
               ?? (targetGB > 0 ? Int64.max : 0))
    }

    static func select(from candidates: [StorageItem], targetBytes: Int64) -> [StorageItem] {
        guard targetBytes > 0 else { return [] }
        let eligible = candidates
            .filter(isPlanningCandidate)
            .sorted { lhs, rhs in
                if lhs.cleanupTier != rhs.cleanupTier {
                    return lhs.cleanupTier! < rhs.cleanupTier!
                }
                let lhsSize = planningBytes(lhs)
                let rhsSize = planningBytes(rhs)
                if lhsSize != rhsSize { return lhsSize > rhsSize }
                if lhs.label != rhs.label { return lhs.label < rhs.label }
                // Same size and same label still has to resolve to one fixed
                // order, or the "same set regardless of scan order" promise
                // above is only true until two rows collide -- which they do:
                // label falls back to `kind`, so two same-size rows of one
                // kind tie. Paths are unique per row.
                return lhs.path < rhs.path
            }
        var selected: [StorageItem] = []
        var total: Int64 = 0
        for item in eligible {
            // Legacy scanner estimates are rounded decimal GiB. Tolerance is
            // for candidate selection only; execution compares exact bytes.
            if total >= max(1, targetBytes - Int64(goalTolerance * Double(StorageBytes.perGiB))) { break }
            selected.append(item)
            total = StorageBytes.adding(total, planningBytes(item)) ?? Int64.max
        }
        return selected
    }
}

struct SpaceGoalWorkspaceList: View {
    @EnvironmentObject private var model: ScanModel
    let storage: StorageSnapshot
    @State private var targetBytes: Int64
    private var targetGB: Double { Double(targetBytes) / Double(StorageBytes.perGiB) }
    @State private var showsPendingMeasurements = false

    init(storage: StorageSnapshot, currentFreeGB: Double? = nil) {
        self.storage = storage
        let achievable = Self.achievableGB(storage)
        let freeGB = currentFreeGB ?? storage.freeGB
        let pressureGap = Double(StorageRecoveryPolicy.default.requiredGainBytes(
            currentAvailableBytes: StorageBytes.fromLegacyGiB(freeGB) ?? 0
        )) / Double(StorageBytes.perGiB)
        let initial = pressureGap > 0 ? pressureGap.rounded(.up) : min(5, max(achievable, 1))
        _targetBytes = State(initialValue: StorageBytes.fromLegacyGiB(
            max(initial, achievable > 0 ? min(achievable, 1) : 1)
        ) ?? StorageBytes.perGiB)
    }

    private var eligibleCandidates: [StorageItem] {
        storage.recoveryCandidates.filter(SpaceGoalSelection.isPlanningCandidate)
    }

    private var achievableGB: Double { Self.achievableGB(storage) }

    /// Upper bound for the goal slider. SwiftUI's Slider divides the range by
    /// `step` and fatals with "max stride must be positive" on a zero-width
    /// range, so `1...max(achievableGB, 1)` hard-crashed the whole page
    /// whenever the cleanable total was greater than zero but at or below
    /// 1GB (one small npm cache is enough). Rounding up and flooring at 2
    /// keeps the range provably wider than its lower bound.
    private var goalUpperBoundGB: Double {
        max(achievableGB.rounded(.up), targetGB.rounded(.up), 2)
    }

    /// A whole-GB goal picker is meaningless below 1GB, and that is exactly
    /// the range where a degenerate slider used to crash -- show the real
    /// achievable total instead of a control the user cannot move.
    private var supportsGoalSlider: Bool { achievableGB >= 1 }

    private var selection: [StorageItem] {
        SpaceGoalSelection.reviewCandidates(storage.recoveryCandidates)
    }

    private var selectedTotalGB: Double {
        Double(selectedTotalBytes) / Double(StorageBytes.perGiB)
    }

    private var selectedTotalBytes: Int64 {
        selection.reduce(0) { StorageBytes.adding($0, SpaceGoalSelection.planningBytes($1)) ?? Int64.max }
    }

    private var measuredSelection: [StorageItem] {
        selection.filter { $0.measureStatus != "timed_out" && $0.sizeGB > 0 }
    }

    private var pendingSelection: [StorageItem] {
        selection.filter { $0.measureStatus == "timed_out" }
    }


    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if eligibleCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("정리 가능한 항목이 없습니다", systemImage: "checkmark.circle")
                            .font(.title3.weight(.semibold))
                        Text("정리 가능한 항목이 없어 목표 모드를 계산할 수 없습니다.")
                            .foregroundStyle(.secondary)
                    }
                    .spaceGoalSurface()
                } else {
                    goalSummary
                    selectedPlan
                    recoveryAction
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("공간 확보 목표 모드")
    }

    private var goalSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "target")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("실제 확보량은 정리 후 확인합니다")
                        .font(.title3.weight(.semibold))
                    Text("공유 블록이 포함된 파일 크기는 실제 회수량이 아닙니다. 후보 크기로 목표 달성을 예측하지 않습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("회수량 미확정")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                SpaceGoalMetric(title: "추가 확보 목표", value: StorageBytes.text(targetBytes))
                SpaceGoalMetric(title: "실제 회수 예상", value: "미확정")
                SpaceGoalMetric(title: "재측정", value: "\(pendingSelection.count)개")
            }


            goalPicker
            Text("권장 최종 여유: 20 GiB · 이 권장값은 선택한 추가 확보량을 바꾸지 않습니다. 후보 점유가 실제 여유 증가량을 보장하지는 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .spaceGoalSurface()
    }

    private var selectedPlan: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("현재 확인된 후보")
                    .font(.headline)
                Text(planSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            if measuredSelection.isEmpty {
                Label("크기가 확인된 후보가 아직 없습니다", systemImage: "ruler")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                candidateRows(measuredSelection)
            }

            if !pendingSelection.isEmpty {
                Divider().padding(.vertical, 8)
                DisclosureGroup(isExpanded: $showsPendingMeasurements) {
                    candidateRows(pendingSelection)
                        .padding(.top, 8)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("재측정이 필요한 항목 \(pendingSelection.count)개")
                                .font(.callout.weight(.semibold))
                            Text("미리보기에서 크기와 사용 여부를 다시 확인합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disclosureGroupStyle(.automatic)
            }
        }
        .spaceGoalSurface()
    }

    private var recoveryAction: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = model.cleanupRecoveryProgress,
               model.cleanupRecoveryPlan == nil {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fraction)
                    HStack {
                        Text(progress.currentLabel)
                        Spacer()
                        Text("\(progress.completedCount)/\(progress.totalCount)")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text("상단의 ‘미리보기 취소’로 삭제 없이 중단할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                model.prepareRecoveryPlan(selection, requestedGainBytes: targetBytes)
            } label: {
                HStack {
                    Label("확보 계획 검토", systemImage: "checklist")
                    Spacer()
                    Text("\(selection.count)개 · 후보 점유 \(StorageBytes.text(selectedTotalBytes))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy || selection.isEmpty)

            Text("경로와 크기를 다시 측정한 뒤 별도 승인 화면을 엽니다. 앱·모델·Simulator·서비스는 이 계획에서 제외합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .spaceGoalSurface()
    }

    @ViewBuilder
    private func candidateRows(_ items: [StorageItem]) -> some View {
        let indexedItems = Array(items.enumerated())
        ForEach(indexedItems, id: \.element.id) { index, item in
            SpaceGoalCandidateRow(item: item, tier: item.cleanupTier!)
            if index < indexedItems.count - 1 {
                Divider().padding(.leading, 44)
            }
        }
    }

    private var goalPicker: some View {
        Group {
            if supportsGoalSlider {
                Slider(value: Binding(
                    get: { targetGB },
                    set: { if let bytes = StorageBytes.fromLegacyGiB($0) { targetBytes = bytes } }
                ), in: 1...goalUpperBoundGB, step: 1)
                    .accessibilityLabel("추가 확보 목표")
                    .accessibilityValue("\(Int(targetGB)) GiB")
            } else {
                Text("확인된 용량이 1 GiB 미만이라 목표 조절은 재측정 후 사용할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // A rescan can shrink what is cleanable while this tab stays on
        // screen; @State survives that, so an old goal could sit outside the
        // new range (slider pinned at its end, header quoting a goal the
        // track cannot reach).
        .onChange(of: goalUpperBoundGB) { newUpperBound in
            targetBytes = StorageBytes.fromLegacyGiB(min(max(targetGB, 1), newUpperBound)) ?? targetBytes
        }
    }

    private var planSubtitle: String {
        "파일 크기는 후보 정렬에만 사용합니다. 공유 블록 때문에 실제 확보량은 더 작을 수 있습니다."
    }

    private static func achievableGB(_ storage: StorageSnapshot) -> Double {
        let bytes = SpaceGoalSelection.select(from: storage.recoveryCandidates, targetBytes: Int64.max)
            .reduce(Int64(0)) { StorageBytes.adding($0, SpaceGoalSelection.planningBytes($1)) ?? Int64.max }
        return Double(bytes) / Double(StorageBytes.perGiB)
    }

}

private struct SpaceGoalMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func spaceGoalSurface() -> some View {
        self
            .padding(16)
            .frame(maxWidth: 1040, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.075), lineWidth: 1)
            }
            .frame(maxWidth: .infinity)
    }
}

private struct SpaceGoalCandidateRow: View {
    let item: StorageItem
    let tier: CleanupTier

    var body: some View {
        WorkspaceStorageItemRow(
            item: item,
            fallbackSymbol: tier == .safe ? "folder.badge.gearshape" : "arrow.triangle.2.circlepath",
            detail: detail,
            sizeTextOverride: item.measureStatus == "timed_out"
                ? "미확인" : StorageBytes.text(StorageBytes.fromLegacyGiB(item.sizeGB)),
            status: tier.shortTitle
        )
        .contextMenu { StorageItemContextMenu(item: item) }
    }

    private var detail: String {
        if item.measureStatus == "timed_out" {
            return "크기와 사용 여부를 다시 측정합니다."
        }
        if item.cleanupID == "transient_workspace" {
            return "정리 전에 경로·소유권·사용 여부를 다시 확인합니다."
        }
        return item.note.isEmpty ? item.action : item.note
    }
}
