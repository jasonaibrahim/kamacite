import CoreGraphics
import Foundation
import Testing
import VWCore
import VWParse
import VWStyle
@testable import VWLayout

// The layout half of live editing: BlockGeometryTree.splice and
// LazyLayout.applySplice must preserve every height outside the spliced
// range (the "glass never moves" guarantee) and honor the prepare()
// anchoring contract.

@Suite struct GeometryTreeSpliceTests {
    /// Mixed setExact + splice sequences against a naive linear model.
    @Test func spliceMatchesLinearModel() {
        var rng = SeededRandom(seed: 7)
        for _ in 0..<40 {
            var model = (0..<rng.int(in: 1..<60)).map { _ in rng.double(in: 8...80) }
            var exactModel = Array(repeating: false, count: model.count)
            var tree = BlockGeometryTree(estimatedHeights: model)

            for _ in 0..<12 {
                if rng.chance(50), !model.isEmpty {
                    let index = rng.int(in: 0..<model.count)
                    let height = rng.double(in: 8...120)
                    tree.setExact(index, height: height)
                    model[index] = height
                    exactModel[index] = true
                } else {
                    let a = rng.int(in: 0..<model.count + 1)
                    let b = rng.int(in: 0..<model.count + 1)
                    let range = min(a, b)..<max(a, b)
                    let fresh = (0..<rng.int(in: 0..<6)).map { _ in rng.double(in: 8...80) }
                    tree.splice(range, with: fresh)
                    model.replaceSubrange(range, with: fresh)
                    exactModel.replaceSubrange(range, with: Array(repeating: false, count: fresh.count))
                }

                #expect(tree.count == model.count)
                #expect(abs(tree.totalHeight - model.reduce(0, +)) < 1e-9)
                for index in model.indices {
                    #expect(abs(tree.height(of: index) - model[index]) < 1e-9)
                    #expect(tree.isExact(index) == exactModel[index])
                    let prefix = model[0..<index].reduce(0, +)
                    #expect(abs(tree.yOffset(of: index) - prefix) < 1e-9)
                }
                if !model.isEmpty {
                    let y = rng.double(in: 0...max(1, tree.totalHeight))
                    var linear = 0
                    var sum = 0.0
                    while linear < model.count - 1, sum + model[linear] <= y {
                        sum += model[linear]
                        linear += 1
                    }
                    #expect(tree.blockIndex(at: y) == linear)
                }
            }
        }
    }
}

@Suite struct LazyLayoutSpliceTests {
    private func makeDocument(_ text: String) -> FlatDocument {
        flatten(parseMarkdown(text))
    }

    private func paragraphs(_ count: Int, tag: String = "Paragraph") -> String {
        (0..<count).map { i in
            "\(tag) number \(i) with enough words to wrap across a couple of lines when shaped at a normal content width."
        }.joined(separator: "\n\n")
    }

    @MainActor private func makeLayout(_ document: FlatDocument) -> LazyLayout {
        let theme = Theme.light
        return LazyLayout(
            document: document, fonts: FontTable(metrics: theme.metrics),
            metrics: theme.metrics, contentWidth: 600, scale: 2
        )
    }

    private func splice(
        _ range: Range<Int>, with markdown: String, byteDelta: Int = 0
    ) -> ContentEditSplice {
        let flat = flatten(parseMarkdown(markdown))
        return ContentEditSplice(
            blockRange: range, tableRange: 0..<0,
            newBlocks: flat.blocks, newTables: [],
            byteDelta: byteDelta, reparsedRange: 0..<0
        )
    }

    private func deletion(_ range: Range<Int>) -> ContentEditSplice {
        ContentEditSplice(
            blockRange: range, tableRange: 0..<0, newBlocks: [], newTables: [],
            byteDelta: 0, reparsedRange: 0..<0
        )
    }

    @Test @MainActor func spliceKeepsHeightsAndCacheOutsideRange() {
        let layout = makeLayout(makeDocument(paragraphs(100)))
        // Shape everything so every height is exact and comparable.
        _ = layout.placedBlocks(in: 0..<layout.contentHeightPts)
        let heightBefore = layout.contentHeightPts
        let offsetsBefore = (0..<layout.blockCount).map { layout.yOffset(of: $0) }
        let shapedBefore = layout.shapedBlockCount

        let adjustment = layout.applySplice(
            splice(50..<52, with: "INSERTED one.\n\nINSERTED two.\n\nINSERTED three."),
            anchorY: 0
        )
        #expect(layout.blockCount == 101)
        // Anchor at the very top: nothing above the splice moved.
        #expect(adjustment == 0)

        // Prefix offsets are BIT-identical (exact heights preserved, not
        // re-estimated).
        for index in 0..<50 {
            #expect(layout.yOffset(of: index) == offsetsBefore[index])
        }
        // Suffix blocks shifted by exactly the total height delta.
        let totalDelta = layout.contentHeightPts - heightBefore
        for oldIndex in 52..<100 {
            let newOffset = layout.yOffset(of: oldIndex + 1)
            #expect(abs(newOffset - (offsetsBefore[oldIndex] + totalDelta)) < 1e-6)
        }
        // Shaped cache survives outside the range: dropped the 2 replaced,
        // the predecessor (quote-bar lookahead), nothing else.
        #expect(layout.shapedBlockCount >= shapedBefore - 3)

        // The spliced-in content shapes on demand with the new runs.
        let placed = layout.placedBlock(at: 50)
        #expect(placed.shaped.text.contains("INSERTED one"))
    }

    @Test @MainActor func anchorAboveSpliceNeverMoves() {
        var rng = SeededRandom(seed: 11)
        let layout = makeLayout(makeDocument(paragraphs(120)))
        _ = layout.prepare(docRange: 0..<2000, anchorY: 0)
        let topOffsets = (0..<10).map { layout.yOffset(of: $0) }

        // 200 random splices strictly below the viewport: the top of the
        // document must never move, and the reported adjustment is always 0 —
        // the zero-drift property (errors must not even accumulate).
        for round in 0..<200 {
            let count = layout.blockCount
            let start = rng.int(in: 20..<count)
            let end = min(count, start + rng.int(in: 0..<4))
            let replacement = rng.chance(75)
                ? splice(start..<end, with: paragraphs(rng.int(in: 1..<4), tag: "Round\(round)"))
                : deletion(start..<end)
            // Only shrink when enough blocks remain to keep anchors valid.
            if replacement.blockDelta < 0, count + replacement.blockDelta < 25 { continue }
            let adjustment = layout.applySplice(replacement, anchorY: 100)
            #expect(adjustment == 0, "round \(round)")
        }
        for index in 0..<10 {
            #expect(layout.yOffset(of: index) == topOffsets[index])
        }
    }

    @Test @MainActor func anchorBelowSpliceShiftsByExactDelta() {
        var rng = SeededRandom(seed: 13)
        for round in 0..<30 {
            let layout = makeLayout(makeDocument(paragraphs(60)))
            _ = layout.placedBlocks(in: 0..<layout.contentHeightPts) // all exact
            let heightBefore = layout.contentHeightPts

            let start = rng.int(in: 2..<20)
            let end = start + rng.int(in: 0..<3)
            // Anchor deep below the splice, mid-block.
            let anchorIndex = rng.int(in: 30..<55)
            let anchorY = layout.yOffset(of: anchorIndex) + 4

            let adjustment = layout.applySplice(
                splice(start..<end, with: paragraphs(rng.int(in: 1..<5), tag: "R\(round)")),
                anchorY: anchorY
            )
            let totalDelta = layout.contentHeightPts - heightBefore
            // The anchor block moved by exactly the splice's height delta and
            // the adjustment reports it: content at anchorY stays on glass.
            #expect(abs(adjustment - totalDelta) < 1e-6, "round \(round)")
            let blockDelta = layout.blockCount - 60
            #expect(
                abs(layout.yOffset(of: anchorIndex + blockDelta) - (anchorY - 4 + totalDelta)) < 1e-6,
                "round \(round)"
            )
        }
    }

    @Test @MainActor func spliceEdgeShapes() {
        // Whole-document replace.
        let layout = makeLayout(makeDocument(paragraphs(10)))
        _ = layout.prepare(docRange: 0..<4000, anchorY: 0)
        _ = layout.applySplice(splice(0..<10, with: "# Fresh\n\nNew body."), anchorY: 0)
        #expect(layout.blockCount == 2)
        #expect(layout.placedBlock(at: 0).shaped.text.contains("Fresh"))

        // Delete everything.
        _ = layout.applySplice(deletion(0..<2), anchorY: 0)
        #expect(layout.blockCount == 0)
        #expect(layout.contentHeightPts == 0)
        #expect(layout.placedBlocks(in: 0..<1000).isEmpty)

        // Insert into the now-empty document.
        let adjustment = layout.applySplice(splice(0..<0, with: "Back from empty."), anchorY: 0)
        #expect(adjustment == 0)
        #expect(layout.blockCount == 1)
        #expect(layout.placedBlock(at: 0).shaped.text.contains("Back"))

        // Pure insertion mid-document.
        let grown = makeLayout(makeDocument(paragraphs(6)))
        _ = grown.placedBlocks(in: 0..<grown.contentHeightPts)
        let before = grown.yOffset(of: 3)
        _ = grown.applySplice(splice(3..<3, with: "Inserted alone."), anchorY: 0)
        #expect(grown.blockCount == 7)
        #expect(grown.yOffset(of: 3) == before)
        #expect(grown.placedBlock(at: 3).shaped.text.contains("Inserted alone"))
    }
}
