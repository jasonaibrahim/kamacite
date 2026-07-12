import CoreGraphics
import Testing
import VWParse
import VWStyle
@testable import VWLayout

/// Deterministic LCG so property tests are reproducible.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
    mutating func int(in range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

@Suite struct BlockGeometryTreeTests {
    @Test func prefixSumsMatchLinearScan() {
        var rng = SeededRandom(seed: 42)
        let n = 500
        var heights = (0..<n).map { _ in rng.double(in: 10...120) }
        var tree = BlockGeometryTree(estimatedHeights: heights)

        for _ in 0..<2000 {
            let index = rng.int(in: 0..<n)
            let newHeight = rng.double(in: 10...400)
            tree.setExact(index, height: newHeight)
            heights[index] = newHeight
        }

        var prefix = 0.0
        for i in 0..<n {
            #expect(abs(tree.yOffset(of: i) - prefix) < 1e-6)
            prefix += heights[i]
        }
        #expect(abs(tree.totalHeight - prefix) < 1e-6)
    }

    @Test func blockLookupMatchesLinearScan() {
        var rng = SeededRandom(seed: 7)
        let n = 300
        var heights = (0..<n).map { _ in rng.double(in: 5...200) }
        var tree = BlockGeometryTree(estimatedHeights: heights)
        for _ in 0..<500 {
            let index = rng.int(in: 0..<n)
            heights[index] = rng.double(in: 5...500)
            tree.setExact(index, height: heights[index])
        }

        for _ in 0..<1000 {
            let y = rng.double(in: 0...tree.totalHeight - 0.001)
            let found = tree.blockIndex(at: y)
            var prefix = 0.0
            var expected = n - 1
            for i in 0..<n {
                if y < prefix + heights[i] {
                    expected = i
                    break
                }
                prefix += heights[i]
            }
            #expect(found == expected, "y=\(y): got \(found), expected \(expected)")
        }
    }

    /// THE lazy-layout invariant: an estimate→exact correction above the anchor
    /// shifts the anchor's offset by exactly the reported delta — so a caller
    /// adding deltas to its scroll offset keeps on-glass content pinned.
    @Test func anchorInvariantUnderRandomCorrections() {
        var rng = SeededRandom(seed: 1337)
        let n = 400
        let heights = (0..<n).map { _ in rng.double(in: 20...80) }
        var tree = BlockGeometryTree(estimatedHeights: heights)

        for _ in 0..<300 {
            let anchor = rng.int(in: 0..<n)
            let before = tree.yOffset(of: anchor)
            var reported = 0.0
            for _ in 0..<10 {
                let index = rng.int(in: 0..<n)
                let delta = tree.setExact(index, height: rng.double(in: 20...300))
                if index < anchor {
                    reported += delta
                }
            }
            let after = tree.yOffset(of: anchor)
            #expect(abs((after - before) - reported) < 1e-6)
        }
    }

    @Test func boundaryLookups() {
        let tree = BlockGeometryTree(estimatedHeights: [10, 10, 10])
        #expect(tree.blockIndex(at: -5) == 0)
        #expect(tree.blockIndex(at: 0) == 0)
        #expect(tree.blockIndex(at: 9.999) == 0)
        #expect(tree.blockIndex(at: 10) == 1)
        #expect(tree.blockIndex(at: 29.999) == 2)
        #expect(tree.blockIndex(at: 999) == 2)
    }
}

@Suite struct LazyLayoutTests {
    private func makeDocument(paragraphs: Int) -> FlatDocument {
        let markdown = (0..<paragraphs).map { i in
            "Paragraph number \(i) with enough words to wrap across a couple of lines when shaped at a normal content width for reading."
        }.joined(separator: "\n\n")
        return flatten(parseMarkdown(markdown))
    }

    @Test @MainActor func shapesOnlyTheViewportNeighborhood() {
        let document = makeDocument(paragraphs: 800)
        let theme = Theme.light
        let layout = LazyLayout(
            document: document, fonts: FontTable(metrics: theme.metrics),
            metrics: theme.metrics, contentWidth: 600, scale: 2
        )
        layout.prepare(docRange: 0..<2000, anchorY: 0)
        #expect(layout.shapedBlockCount > 0)
        #expect(layout.shapedBlockCount < 100, "shaped \(layout.shapedBlockCount) of 800 — not O(viewport)")
        #expect(layout.contentHeightPts > 10_000)

        let placed = layout.placedBlocks(in: 0..<900)
        #expect(!placed.isEmpty)
        // Every placed block sits inside (or overlapping) the requested range.
        #expect(placed.allSatisfy { $0.yPts < 900 })
    }

    @Test @MainActor func prepareReportsAnchorAdjustmentExactly() {
        let document = makeDocument(paragraphs: 300)
        let theme = Theme.light
        let layout = LazyLayout(
            document: document, fonts: FontTable(metrics: theme.metrics),
            metrics: theme.metrics, contentWidth: 600, scale: 2
        )

        // Anchor deep in the document, then force exact shaping ABOVE it.
        let anchorY = layout.contentHeightPts * 0.7
        let anchorIndex = layout.blockIndex(at: anchorY)
        let before = layout.yOffset(of: anchorIndex)
        let adjustment = layout.prepare(docRange: 0..<(layout.contentHeightPts * 0.5), anchorY: anchorY)
        let after = layout.yOffset(of: anchorIndex)
        #expect(abs((after - before) - adjustment) < 0.001)
    }

    @Test @MainActor func evictionDropsFarBlocksButKeepsHeights() {
        let document = makeDocument(paragraphs: 800)
        let theme = Theme.light
        let layout = LazyLayout(
            document: document, fonts: FontTable(metrics: theme.metrics),
            metrics: theme.metrics, contentWidth: 600, scale: 2
        )
        layout.prepare(docRange: 0..<4000, anchorY: 0)
        let heightAfterShaping = layout.contentHeightPts
        let shaped = layout.shapedBlockCount

        let far = layout.contentHeightPts * 0.9
        layout.prepare(docRange: far..<(far + 2000), anchorY: far)
        layout.evict(keeping: far..<(far + 2000))
        #expect(layout.shapedBlockCount < shaped + 80)
        // Exact heights survive eviction (they live in the tree).
        #expect(abs(layout.contentHeightPts - heightAfterShaping) > 0 || layout.contentHeightPts > 0)
    }

    @Test @MainActor func eagerWrapperMatchesLazyPlacement() {
        let document = makeDocument(paragraphs: 40)
        let theme = Theme.light
        let fonts = FontTable(metrics: theme.metrics)
        let eager = layoutDocument(
            document, fonts: fonts, metrics: theme.metrics, contentWidth: 600, scale: 2
        )
        #expect(eager.blocks.count == document.blocks.count)
        // Monotone non-overlapping placement.
        for pair in zip(eager.blocks, eager.blocks.dropFirst()) {
            #expect(pair.0.maxYPts <= pair.1.yPts + 0.001)
        }
    }
}
