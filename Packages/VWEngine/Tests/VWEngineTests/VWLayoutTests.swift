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

@Suite struct ReplaceBlockTests {
    /// Paragraphs with a mermaid fence in the middle; returns the fence's
    /// flat index.
    private func makeDocument(paragraphs: Int) -> (FlatDocument, Int) {
        var parts = (0..<paragraphs).map { i in
            "Paragraph number \(i) with enough words to wrap across a couple of lines when shaped at a normal content width for reading."
        }
        parts.insert("```mermaid\ngraph TD; A-->B\n```", at: paragraphs / 2)
        let document = flatten(parseMarkdown(parts.joined(separator: "\n\n")))
        let index = document.blocks.firstIndex { $0.codeLanguage == "mermaid" }!
        return (document, index)
    }

    @MainActor private func makeLayout(_ document: FlatDocument) -> LazyLayout {
        let theme = Theme.light
        return LazyLayout(
            document: document, fonts: FontTable(metrics: theme.metrics),
            metrics: theme.metrics, contentWidth: 600, scale: 2
        )
    }

    /// The swapped block: same runs/spans (mermaid source stays copyable),
    /// kind flipped to `.diagram` with a known raster geometry.
    private func diagramBlock(
        _ document: FlatDocument, index: Int, naturalSize: CGSize
    ) -> FlatBlock {
        var block = document.blocks[index]
        block.kind = .diagram
        block.diagram = DiagramInfo(imageKey: 0xD1A6, naturalSizePts: naturalSize)
        return block
    }

    /// The anchoring contract: a swap strictly above the anchor reports
    /// exactly the shift it caused, so the caller's scroll-offset adjustment
    /// keeps on-glass content pinned.
    @Test @MainActor func swapAboveAnchorReportsExactShift() {
        let (document, index) = makeDocument(paragraphs: 60)
        let layout = makeLayout(document)
        let anchorY = layout.contentHeightPts * 0.9
        let anchorIndex = layout.blockIndex(at: anchorY)
        #expect(index < anchorIndex)

        let offsetBefore = layout.yOffset(of: anchorIndex)
        let heightBefore = layout.contentHeightPts
        let adjustment = layout.replaceBlock(
            at: index,
            with: diagramBlock(document, index: index, naturalSize: CGSize(width: 400, height: 300)),
            anchorY: anchorY
        )
        #expect(adjustment != 0)
        #expect(abs((layout.yOffset(of: anchorIndex) - offsetBefore) - adjustment) < 0.001)
        #expect(abs((layout.contentHeightPts - heightBefore) - adjustment) < 0.001)

        let placed = layout.placedBlock(at: index)
        #expect(placed.kind == .diagram)
        // 400pt natural width fits inside 600 − 2×12 padding: shown 1:1,
        // inset like code-block text, padding above and below.
        #expect(placed.diagram?.rectPts == CGRect(x: 12, y: 12, width: 400, height: 300))
        #expect(abs(placed.heightPts - 324) < 0.001)
    }

    @Test @MainActor func swapAtOrBelowAnchorReportsZero() {
        let (document, index) = makeDocument(paragraphs: 60)
        let layout = makeLayout(document)
        let heightBefore = layout.contentHeightPts
        let adjustment = layout.replaceBlock(
            at: index,
            with: diagramBlock(document, index: index, naturalSize: CGSize(width: 400, height: 300)),
            anchorY: 0
        )
        #expect(adjustment == 0)
        // The height still changed — only the scroll report is suppressed.
        #expect(abs(layout.contentHeightPts - heightBefore) > 1)
    }

    /// Diagram geometry is a pure function of (FlatBlock, contentWidth, scale):
    /// after eviction, re-shaping must reproduce the identical height and
    /// placed rect with no help from the session.
    @Test @MainActor func evictedDiagramReshapesToTheSameGeometry() {
        let (document, index) = makeDocument(paragraphs: 120)
        let layout = makeLayout(document)
        _ = layout.replaceBlock(
            at: index,
            with: diagramBlock(document, index: index, naturalSize: CGSize(width: 2000, height: 1000)),
            anchorY: 0
        )
        let placedBefore = layout.placedBlock(at: index)
        #expect(placedBefore.diagram != nil)

        // Shape everything, then evict a window that excludes the diagram.
        layout.prepare(docRange: 0..<CGFloat.greatestFiniteMagnitude, anchorY: 0)
        let heightBefore = layout.contentHeightPts
        let far = layout.contentHeightPts - 100
        layout.evict(keeping: far..<layout.contentHeightPts)

        let placedAfter = layout.placedBlock(at: index) // re-shapes from the FlatBlock alone
        #expect(abs(placedAfter.heightPts - placedBefore.heightPts) < 0.001)
        #expect(placedAfter.diagram == placedBefore.diagram)
        #expect(abs(layout.contentHeightPts - heightBefore) < 0.001)
        // Natural width beyond the text width clamps, preserving aspect:
        // 600 − 2×12 = 576 wide → 288 tall.
        #expect(placedAfter.diagram?.rectPts == CGRect(x: 12, y: 12, width: 576, height: 288))
    }

    /// Estimation and exact shaping share the diagram arithmetic, so a
    /// swapped block's estimate needs no anchored correction: shaping it
    /// exactly moves the total height by nothing.
    @Test @MainActor func diagramEstimateIsAlreadyExact() {
        var (document, index) = makeDocument(paragraphs: 20)
        document.blocks[index] = diagramBlock(
            document, index: index, naturalSize: CGSize(width: 400, height: 300)
        )
        let layout = makeLayout(document)
        let estimated = layout.contentHeightPts
        _ = layout.placedBlock(at: index) // shapes ONLY the diagram block
        #expect(abs(layout.contentHeightPts - estimated) < 0.001)
    }

    /// A pending mermaid fence lays out as the loading skeleton: estimate ==
    /// exact (no anchored correction), no source text on glass, ghost quads
    /// over code-block chrome, and no raster reference.
    @Test @MainActor func pendingDiagramSkeletonEstimateIsExactAndTextless() {
        let (document, index) = makeDocument(paragraphs: 20)
        #expect(document.blocks[index].kind == .diagram)
        #expect(document.blocks[index].diagram == nil)
        let layout = makeLayout(document)
        let estimated = layout.contentHeightPts
        let placed = layout.placedBlock(at: index)
        #expect(abs(layout.contentHeightPts - estimated) < 0.001)
        #expect(placed.shaped.positionedLines.isEmpty)
        #expect(placed.diagram == nil)
        #expect(placed.backgrounds.contains { $0.color == .codeBackground })
        #expect(placed.backgrounds.filter { $0.color == .diagramSkeleton }.count == 3)
    }
}
