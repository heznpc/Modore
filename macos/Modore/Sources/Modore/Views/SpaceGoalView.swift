import SwiftUI

/// Given a target amount of space to free, deterministically picks the
/// fewest, largest safely-cleanable candidates whose sizes sum to at least
/// that target. "Deterministic" here means: no randomness, and ties break by
/// label so the same candidate set always produces the same selection
/// regardless of the scan's original ordering -- not an exact/optimal subset
/// sum, just a simple, explainable greedy-largest-first rule.
enum SpaceGoalSelection {
    /// Sizes arrive rounded to a tenth of a GB, and a tenth is not exact in
    /// binary: four items truly summing to 3.0 add up to 2.9999999999999996,
    /// so a bare `>=` walked past the exact-match set and appended one more
    /// item than the goal needed, then reported the result as short of it.
    private static let goalTolerance = 0.000_001

    static func select(from candidates: [StorageItem], targetGB: Double) -> [StorageItem] {
        guard targetGB > 0 else { return [] }
        let eligible = candidates
            .filter(\.canCleanup)
            .sorted { lhs, rhs in
                if lhs.sizeGB != rhs.sizeGB { return lhs.sizeGB > rhs.sizeGB }
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
            total += item.sizeGB
        }
        return selected
    }
}

struct SpaceGoalWorkspaceList: View {
    let storage: StorageSnapshot
    @State private var targetGB: Double

    init(storage: StorageSnapshot) {
        self.storage = storage
        let achievable = Self.achievableGB(storage)
        _targetGB = State(initialValue: min(5, max(achievable, 1)))
    }

    private var eligibleCandidates: [StorageItem] {
        storage.cleanupCandidates.filter(\.canCleanup)
    }

    private var achievableGB: Double { Self.achievableGB(storage) }

    /// Upper bound for the goal slider. SwiftUI's Slider divides the range by
    /// `step` and fatals with "max stride must be positive" on a zero-width
    /// range, so `1...max(achievableGB, 1)` hard-crashed the whole page
    /// whenever the cleanable total was greater than zero but at or below
    /// 1GB (one small npm cache is enough). Rounding up and flooring at 2
    /// keeps the range provably wider than its lower bound.
    private var goalUpperBoundGB: Double { max(achievableGB.rounded(.up), 2) }

    /// A whole-GB goal picker is meaningless below 1GB, and that is exactly
    /// the range where a degenerate slider used to crash -- show the real
    /// achievable total instead of a control the user cannot move.
    private var supportsGoalSlider: Bool { achievableGB >= 1 }

    private var selection: [StorageItem] {
        SpaceGoalSelection.select(from: storage.cleanupCandidates, targetGB: targetGB)
    }

    private var selectedTotalGB: Double {
        selection.reduce(0) { $0 + $1.sizeGB }
    }

    private var metGoal: Bool { selectedTotalGB >= targetGB }

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
                        subtitle: "실행은 하지 않으며, 목표에 맞는 조합만 계산합니다. 실제 실행은 각 항목을 눌러 개별적으로 검토·승인하세요.",
                        value: String(format: "%.0fGB", targetGB)
                    )
                }

                Section {
                    ForEach(selection) { item in
                        CleanupCandidateRow(item: item)
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
        storage.cleanupCandidates.filter(\.canCleanup).reduce(0) { $0 + $1.sizeGB }
    }
}
