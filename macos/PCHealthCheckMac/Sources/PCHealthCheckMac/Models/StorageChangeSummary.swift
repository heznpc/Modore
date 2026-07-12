import Foundation

struct StorageChangeSummary: Equatable {
    let previous: StorageHistoryEntry
    let current: StorageHistoryEntry
    let itemChanges: [StorageItemChange]
    let largestChanges: [StorageItemChange]
    let growingItems: [StorageItemChange]
    let shrinkingItems: [StorageItemChange]
    let observedGrowthGB: Double
    let observedShrinkGB: Double
    let trackedNetDeltaGB: Double

    var freeDeltaGB: Double { current.freeGB - previous.freeGB }
    var consumedGB: Double { max(0, -freeDeltaGB) }
    var recoveredGB: Double { max(0, freeDeltaGB) }

    var primaryCauseCandidates: [StorageItemChange] {
        if consumedGB >= 0.05 { return growingItems }
        if recoveredGB >= 0.05 { return shrinkingItems }
        return []
    }

    var primaryCause: StorageItemChange? {
        primaryCauseCandidates.first
    }

    var oppositeDirectionChanges: [StorageItemChange] {
        if consumedGB >= 0.05 { return shrinkingItems }
        if recoveredGB >= 0.05 { return growingItems }
        return []
    }

    var causeNotCaptured: Bool {
        (consumedGB >= 0.05 || recoveredGB >= 0.05) && primaryCause == nil
    }

    var unattributedConsumedGB: Double {
        max(0, consumedGB - observedGrowthGB)
    }

    var unattributedRecoveredGB: Double {
        max(0, recoveredGB - observedShrinkGB)
    }

    init?(entries: [StorageHistoryEntry]) {
        guard entries.count >= 2 else { return nil }
        let sorted = entries.sorted { $0.capturedAt < $1.capturedAt }
        previous = sorted[sorted.count - 2]
        current = sorted[sorted.count - 1]
        let changes = Self.changes(previous: previous, current: current)
        let growing = changes.filter { $0.deltaGB >= 0.05 }.sorted { $0.deltaGB > $1.deltaGB }
        let shrinking = changes.filter { $0.deltaGB <= -0.05 }.sorted { $0.deltaGB < $1.deltaGB }
        let exclusive = Self.exclusiveRootChanges(changes)
        itemChanges = changes
        largestChanges = changes.sorted { abs($0.deltaGB) > abs($1.deltaGB) }
        growingItems = growing
        shrinkingItems = shrinking
        let measuredExclusive = exclusive.filter(\.hasMeasuredEndpoints)
        observedGrowthGB = measuredExclusive
            .filter { $0.deltaGB >= 0.05 }
            .reduce(0) { $0 + $1.deltaGB }
        observedShrinkGB = measuredExclusive
            .filter { $0.deltaGB <= -0.05 }
            .reduce(0) { $0 + abs($1.deltaGB) }
        trackedNetDeltaGB = measuredExclusive.reduce(0) { $0 + $1.deltaGB }
    }

    private static func changes(
        previous: StorageHistoryEntry,
        current: StorageHistoryEntry
    ) -> [StorageItemChange] {
        let before = indexedItems(previous.items)
        let after = indexedItems(current.items)
        let keys = Set(before.keys).union(after.keys)
        return keys.sorted().compactMap { key in
            let old = before[key]
            let row = after[key]
            if old?.measureStatus == "timed_out" || row?.measureStatus == "timed_out" {
                return nil
            }
            guard let source = row ?? old else { return nil }
            let beforeGB = old?.sizeGB ?? 0
            let afterGB = row?.sizeGB ?? 0
            guard abs(afterGB - beforeGB) >= 0.05 else { return nil }
            return StorageItemChange(
                key: key,
                label: source.label,
                category: source.category,
                path: source.path,
                beforeGB: beforeGB,
                afterGB: afterGB,
                wasPresent: old != nil,
                isPresent: row != nil
            )
        }
    }

    private static func indexedItems(_ items: [StorageHistoryItem]) -> [String: StorageHistoryItem] {
        items.reduce(into: [:]) { result, item in
            let identity = StorageHistoryEntry.historyIdentity(
                category: item.category,
                kind: item.kind,
                cleanupID: item.cleanupID,
                path: item.path
            )
            // Historical files may contain the former recipe-only key more than once.
            // A path-bound identity preserves each real target; an exact duplicate is one target.
            result[identity] = item
        }
    }

    private static func exclusiveRootChanges(_ changes: [StorageItemChange]) -> [StorageItemChange] {
        let sorted = changes.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.path.count < $1.path.count
        }
        var roots: [StorageItemChange] = []
        for change in sorted {
            let path = StorageHistoryEntry.normalizedPath(change.path)
            let covered = roots.contains { root in
                guard root.category == change.category,
                      (root.deltaGB > 0) == (change.deltaGB > 0) else {
                    return false
                }
                let rootPath = StorageHistoryEntry.normalizedPath(root.path)
                return path == rootPath || path.hasPrefix(rootPath + "/")
            }
            if !covered {
                roots.append(change)
            }
        }
        return roots
    }
}
