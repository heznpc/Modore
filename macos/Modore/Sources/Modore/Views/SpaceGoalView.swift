import SwiftUI

/// Given a target amount of space to free, deterministically picks the
/// fewest, largest safely-cleanable candidates whose sizes sum to at least
/// that target. "Deterministic" here means: no randomness, and ties break by
/// label so the same candidate set always produces the same selection
/// regardless of the scan's original ordering -- not an exact/optimal subset
/// sum, just a simple, explainable greedy-largest-first rule.
enum SpaceGoalSelection {
    static func select(from candidates: [StorageItem], targetGB: Double) -> [StorageItem] {
        guard targetGB > 0 else { return [] }
        let eligible = candidates
            .filter(\.canCleanup)
            .sorted { lhs, rhs in
                if lhs.sizeGB != rhs.sizeGB { return lhs.sizeGB > rhs.sizeGB }
                return lhs.label < rhs.label
            }
        var selected: [StorageItem] = []
        var total = 0.0
        for item in eligible {
            if total >= targetGB { break }
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
            Slider(value: $targetGB, in: 1...max(achievableGB, 1), step: 1)
            HStack {
                Text("목표: \(String(format: "%.0f", targetGB))GB")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("정리 가능 총합 \(String(format: "%.1f", achievableGB))GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private static func achievableGB(_ storage: StorageSnapshot) -> Double {
        storage.cleanupCandidates.filter(\.canCleanup).reduce(0) { $0 + $1.sizeGB }
    }
}
