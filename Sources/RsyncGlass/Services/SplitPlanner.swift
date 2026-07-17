import Foundation

struct StreamPlan {
    let itemNames: [String]
    let totalKB: Int
}

enum SplitPlanner {
    /// Greedily balances items across `streamCount` buckets by size (largest-first
    /// assigned to the currently-lightest bucket), so each parallel rsync
    /// process carries a roughly equal share of bytes.
    static func plan(items: [SizedItem], streamCount: Int) -> [StreamPlan] {
        let count = max(1, streamCount)
        var buckets = Array(repeating: (names: [String](), totalKB: 0), count: count)
        let sorted = items.sorted { $0.sizeKB > $1.sizeKB }

        for item in sorted {
            let lightestIndex = buckets.indices.min { buckets[$0].totalKB < buckets[$1].totalKB }!
            buckets[lightestIndex].names.append(item.name)
            buckets[lightestIndex].totalKB += item.sizeKB
        }

        return buckets
            .filter { !$0.names.isEmpty }
            .map { StreamPlan(itemNames: $0.names, totalKB: max($0.totalKB, 1)) }
    }
}
