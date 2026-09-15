import Foundation

/// Picks cache recipes before recipes that require a download or rebuild, then
/// takes the largest entries in each tier. Individual-only choices such as app
/// removal, models and simulators never enter a one-approval recovery plan.
enum SpaceGoalSelection {
    // Scan snapshots create fresh UUIDs. Preserve user exclusions by resource.
    static func key(_ item: StorageItem) -> String {
        item.cleanupID + "\u{0}" + item.path
    }
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
