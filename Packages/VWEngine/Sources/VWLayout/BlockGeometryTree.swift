import Foundation

/// Fenwick (binary indexed) tree over per-block composite heights — the spine
/// of lazy layout. Heights start as estimates and are replaced by exact values
/// as blocks get shaped; both y-offset queries and y→block lookups are
/// O(log n), and an estimate→exact swap reports the delta so the caller can
/// scroll-anchor (corrections above the viewport must never move visible
/// pixels).
///
/// "Composite" height = spacing-before + block height + spacing-after, so
/// prefix sums are document y-offsets directly.
public struct BlockGeometryTree: Sendable {
    private var tree: [Double] // 1-based Fenwick partial sums
    private var heights: [Double]
    private var exact: [Bool]
    public private(set) var totalHeight: Double

    public var count: Int { heights.count }

    public init(estimatedHeights: [Double]) {
        heights = estimatedHeights
        exact = Array(repeating: false, count: estimatedHeights.count)
        tree = Array(repeating: 0, count: estimatedHeights.count + 1)
        totalHeight = 0
        // O(n) Fenwick construction.
        for (i, h) in estimatedHeights.enumerated() {
            let index = i + 1
            tree[index] += h
            let parent = index + (index & -index)
            if parent <= estimatedHeights.count {
                tree[parent] += tree[index]
            }
            totalHeight += h
        }
    }

    public func isExact(_ index: Int) -> Bool {
        exact[index]
    }

    public func height(of index: Int) -> Double {
        heights[index]
    }

    /// Document y-offset of the top of block `index` (sum of heights 0..<index).
    public func yOffset(of index: Int) -> Double {
        var sum = 0.0
        var i = index // prefix of the first `index` blocks == 1-based index of predecessor
        while i > 0 {
            sum += tree[i]
            i -= i & -i
        }
        return sum
    }

    /// Replace a height (estimate → exact, or exact → exact after reflow).
    /// Returns the delta applied.
    @discardableResult
    public mutating func setExact(_ index: Int, height: Double) -> Double {
        let delta = height - heights[index]
        exact[index] = true
        guard delta != 0 else { return 0 }
        heights[index] = height
        totalHeight += delta
        var i = index + 1
        while i <= count {
            tree[i] += delta
            i += i & -i
        }
        return delta
    }

    /// Downgrade all heights to estimates again (width/scale change keeps the
    /// tree but nothing is exact anymore). Heights stay — a stale exact height
    /// is a better estimate than the original guess.
    public mutating func markAllEstimated() {
        for i in exact.indices {
            exact[i] = false
        }
    }

    /// Index of the block containing document offset `y` (clamped). Binary
    /// lifting over the Fenwick tree: O(log n), no per-node prefix queries.
    public func blockIndex(at y: Double) -> Int {
        guard count > 0 else { return 0 }
        if y <= 0 { return 0 }
        if y >= totalHeight { return count - 1 }

        var index = 0
        var remaining = y
        var step = 1 << (63 - (UInt64(count).leadingZeroBitCount))
        while step > 0 {
            let next = index + step
            // <= so a y exactly on a boundary resolves to the block starting there.
            if next <= count, tree[next] <= remaining {
                index = next
                remaining -= tree[next]
            }
            step >>= 1
        }
        // `index` = number of whole blocks ending at or before y.
        return min(index, count - 1)
    }
}
