import SwiftUI

/// Picks cache recipes before recipes that require a download or rebuild, then
/// takes the largest entries in each tier. Individual-only choices such as app
/// removal, models and simulators never enter a one-approval recovery plan.
enum SpaceGoalSelection {
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
        guard item.measureStatus != "timed_out" else { return 0 }
        return item.sizeGB.isFinite ? max(0, item.sizeGB) : 0
    }

    static func select(from candidates: [StorageItem], targetGB: Double) -> [StorageItem] {
        guard targetGB > 0 else { return [] }
        let eligible = candidates
            .filter { $0.cleanupTier != nil }
            .sorted { lhs, rhs in
                if lhs.cleanupTier != rhs.cleanupTier {
                    return lhs.cleanupTier! < rhs.cleanupTier!
                }
                let lhsSize = planningSizeGB(lhs)
                let rhsSize = planningSizeGB(rhs)
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
        var total = 0.0
        for item in eligible {
            if total >= targetGB - goalTolerance { break }
            selected.append(item)
            total += planningSizeGB(item)
        }
        return selected
    }
}

struct SpaceGoalWorkspaceList: View {
    @EnvironmentObject private var model: ScanModel
    let storage: StorageSnapshot
    @State private var targetGB: Double

    init(storage: StorageSnapshot, currentFreeGB: Double? = nil) {
        self.storage = storage
        let achievable = Self.achievableGB(storage)
        let freeGB = currentFreeGB ?? storage.freeGB
        let pressureGap = StorageRecoveryPolicy.requiredGainGB(currentFreeGB: freeGB)
        let initial = pressureGap > 0 ? pressureGap.rounded(.up) : min(5, max(achievable, 1))
        _targetGB = State(initialValue: max(initial, achievable > 0 ? min(achievable, 1) : 1))
    }

    private var eligibleCandidates: [StorageItem] {
        storage.recoveryCandidates.filter { $0.cleanupTier != nil }
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
        SpaceGoalSelection.select(from: storage.recoveryCandidates, targetGB: targetGB)
    }

    private var selectedTotalGB: Double {
        selection.reduce(0) { $0 + SpaceGoalSelection.planningSizeGB($1) }
    }

    private var metGoal: Bool { selectedTotalGB >= targetGB - 0.000_001 }

    var body: some View {
        List {
            if eligibleCandidates.isEmpty {
                Section {
                    Text("정리 가능한 항목이 없어 목표 모드를 계산할 수 없습니다.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    goalPicker
                } header: {
                    NativeSectionHeader(
                        title: "확보 목표",
                        subtitle: "캐시를 먼저 쓰고 부족할 때만 재생성 항목을 더합니다. 아래 계획 전체를 한 번에 검토·승인할 수 있습니다.",
                        value: String(format: "%.0fGB", targetGB)
                    )
                }

                Section {
                    ForEach(selection) { item in
                        SpaceGoalCandidateRow(item: item, tier: item.cleanupTier!)
                    }
                } header: {
                    NativeSectionHeader(
                        title: metGoal ? "선택된 조합" : "선택된 조합 (목표 미달)",
                        subtitle: metGoal
                            ? "이 \(selection.count)개 항목이면 목표를 충족합니다. 큰 항목부터 채운 결과입니다."
                            : "정리 가능한 항목을 모두 더해도 목표에 못 미칩니다. 실제로 확보 가능한 전체를 보여줍니다.",
                        value: String(format: "%.1fGB", selectedTotalGB)
                    )
                }

                Section {
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
                        model.prepareRecoveryPlan(
                            selection,
                            desiredFreeGB: desiredFreeGB
                        )
                    } label: {
                        HStack {
                            Label("\(selection.count)개 계획 검토…", systemImage: "checklist")
                            Spacer()
                            Text(String(format: "재측정 전 약 %.1fGB", selectedTotalGB))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || selection.isEmpty)

                    Text("버튼을 누르면 모든 경로와 크기를 다시 측정합니다. 삭제는 다음 승인 화면에서 한 번 더 확인한 뒤에만 시작합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    NativeSectionHeader(
                        title: "한 번에 실행",
                        subtitle: "앱 제거·모델·Simulator·서비스 항목은 이 계획에 포함하지 않습니다.",
                        value: "승인 1회"
                    )
                }
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("공간 확보 목표 모드")
    }

    @ViewBuilder
    private var goalPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if supportsGoalSlider {
                Slider(value: $targetGB, in: 1...goalUpperBoundGB, step: 1)
            }
            HStack {
                Text(supportsGoalSlider
                    ? "목표: \(String(format: "%.0f", targetGB))GB"
                    : "정리 가능한 용량이 1GB 미만이라 목표를 나눌 수 없습니다.")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("정리 가능 총합 \(String(format: "%.1f", achievableGB))GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // A rescan can shrink what is cleanable while this tab stays on
        // screen; @State survives that, so an old goal could sit outside the
        // new range (slider pinned at its end, header quoting a goal the
        // track cannot reach).
        .onChange(of: goalUpperBoundGB) { newUpperBound in
            targetGB = min(max(targetGB, 1), newUpperBound)
        }
    }

    private static func achievableGB(_ storage: StorageSnapshot) -> Double {
        SpaceGoalSelection.select(from: storage.recoveryCandidates, targetGB: .greatestFiniteMagnitude)
            .reduce(0) { $0 + SpaceGoalSelection.planningSizeGB($1) }
    }

    private var desiredFreeGB: Double {
        let current = model.currentFreeGB ?? storage.freeGB
        if current < StorageRecoveryPolicy.desiredFreeGB {
            return StorageRecoveryPolicy.desiredFreeGB
        }
        return current + targetGB
    }
}

private struct SpaceGoalCandidateRow: View {
    let item: StorageItem
    let tier: CleanupTier

    var body: some View {
        WorkspaceStorageItemRow(
            item: item,
            fallbackSymbol: tier == .safe ? "folder.badge.gearshape" : "arrow.triangle.2.circlepath",
            detail: item.note.isEmpty ? item.action : item.note,
            status: tier.shortTitle
        )
        .contextMenu { StorageItemContextMenu(item: item) }
    }
}
