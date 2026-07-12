import CoreGraphics
import Foundation
import VWCore
import VWStyle
import VWText

// Viewport-only layout. Every block gets a cheap height ESTIMATE up front
// (O(n), no shaping); only blocks near the viewport are actually shaped, and
// their exact heights replace estimates in the geometry tree. Corrections for
// blocks above the anchor are summed and returned so the caller can shift the
// scroll offset — content on glass never moves because an estimate somewhere
// above it was wrong.

/// Spacing rules shared by estimation and exact placement — they MUST agree,
/// or estimates would be biased by construction.
func spacingBefore(_ kind: FlatBlockKind, metrics: Metrics) -> CGFloat {
    switch kind {
    case .heading: metrics.headingSpacingBefore
    case .rule: metrics.ruleSpacing
    default: 0
    }
}

func spacingAfter(_ kind: FlatBlockKind, metrics: Metrics) -> CGFloat {
    switch kind {
    case .heading: metrics.headingSpacingAfter
    case .paragraph: metrics.paragraphSpacing
    case .codeBlock: metrics.codeBlockSpacing
    case .listItem: metrics.listItemSpacing
    case .tableRow: 2
    case .rule: metrics.ruleSpacing
    }
}

@MainActor
public final class LazyLayout {
    /// Mutated only by replaceRuns(at:with:) — async syntax highlighting.
    public private(set) var document: FlatDocument
    public let fonts: FontTable
    public let metrics: Metrics
    public private(set) var contentWidth: CGFloat
    public private(set) var scale: CGFloat

    private var tree: BlockGeometryTree
    private struct CachedBlock {
        let shaped: ShapedBlockText
        let blockHeightPts: CGFloat
        let textInsetPts: CGPoint
        let backgrounds: [BackgroundQuad]
    }
    private var cache: [Int: CachedBlock] = [:]

    public init(
        document: FlatDocument, fonts: FontTable, metrics: Metrics,
        contentWidth: CGFloat, scale: CGFloat
    ) {
        self.document = document
        self.fonts = fonts
        self.metrics = metrics
        self.contentWidth = contentWidth
        self.scale = scale
        self.tree = BlockGeometryTree(estimatedHeights: Self.estimate(
            document: document, fonts: fonts, metrics: metrics, contentWidth: contentWidth
        ))
    }

    public var blockCount: Int { document.blocks.count }
    public var contentHeightPts: CGFloat { CGFloat(tree.totalHeight) }

    /// Fraction of blocks currently shaped — the O(viewport) evidence.
    public var shapedBlockCount: Int { cache.count }

    // MARK: - Estimation

    private static func estimate(
        document: FlatDocument, fonts: FontTable, metrics: Metrics, contentWidth: CGFloat
    ) -> [Double] {
        var slots: [FontClass: CGFloat] = [:]
        var widths: [FontClass: CGFloat] = [:]

        return document.blocks.map { block in
            let baseClass = block.baseFontClass
            let slotHeight = slots[baseClass] ?? {
                let h = fonts.lineSlot(for: baseClass).height
                slots[baseClass] = h
                return h
            }()
            let charWidth = widths[baseClass] ?? {
                let w = fonts.averageCharacterWidth(for: baseClass)
                widths[baseClass] = w
                return w
            }()

            let indent = CGFloat(block.indentLevel) * metrics.indentWidth
            let padding = block.kind == .codeBlock ? metrics.codeBlockPadding : 0
            let textWidth = max(40, contentWidth - indent - padding * 2)

            let blockHeight: CGFloat
            if block.kind == .rule {
                blockHeight = metrics.ruleThickness
            } else {
                // UTF-8 length as the char-count proxy (O(1) per run): CJK
                // over-counts bytes but is ~2× wide, so it roughly cancels.
                var units = 0
                var hardBreaks = 0
                for run in block.runs {
                    units += run.text.utf8.count
                    if block.kind == .codeBlock {
                        hardBreaks += run.text.utf8.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
                    } else if run.text == "\n" {
                        hardBreaks += 1
                    }
                }
                let wrapped = Int((CGFloat(units) * charWidth / textWidth).rounded(.up))
                let lines = max(1, max(wrapped, hardBreaks + 1))
                blockHeight = CGFloat(lines) * slotHeight + padding * 2
            }

            return Double(spacingBefore(block.kind, metrics: metrics) + blockHeight
                + spacingAfter(block.kind, metrics: metrics))
        }
    }

    // MARK: - Exact shaping

    /// Shape every block whose composite range intersects `docRange`, replacing
    /// estimated heights. Returns the scroll adjustment: the net height delta
    /// of blocks strictly above the block containing `anchorY`.
    @discardableResult
    public func prepare(docRange: Range<CGFloat>, anchorY: CGFloat) -> CGFloat {
        guard blockCount > 0 else { return 0 }
        var adjustment: CGFloat = 0
        let anchorIndex = tree.blockIndex(at: Double(max(0, anchorY)))

        var index = tree.blockIndex(at: Double(docRange.lowerBound))
        // Running y from the block's own (pre-shaping) offset: a block's height
        // delta only shifts LATER blocks, and the walk reads post-shaping
        // heights, so the running sum stays consistent.
        var y = CGFloat(tree.yOffset(of: index))
        while index < blockCount, y < docRange.upperBound {
            if !tree.isExact(index) || cache[index] == nil {
                let delta = shapeExact(index)
                if index < anchorIndex {
                    adjustment += delta
                }
            }
            y += CGFloat(tree.height(of: index))
            index += 1
        }
        return adjustment
    }

    @discardableResult
    private func shapeExact(_ index: Int) -> CGFloat {
        let block = document.blocks[index]
        let indent = CGFloat(block.indentLevel) * metrics.indentWidth
        let padding = block.kind == .codeBlock ? metrics.codeBlockPadding : 0
        let textWidth = max(40, contentWidth - indent - padding * 2)
        let shaped = shapeBlock(block, fonts: fonts, width: textWidth, scale: scale)

        let blockHeight: CGFloat
        var backgrounds: [BackgroundQuad] = []
        switch block.kind {
        case .rule:
            blockHeight = metrics.ruleThickness
            backgrounds.append(BackgroundQuad(
                rectPts: CGRect(x: indent, y: 0, width: max(0, contentWidth - indent), height: blockHeight),
                color: .rule
            ))
        case .codeBlock:
            blockHeight = shaped.heightPts + padding * 2
            backgrounds.append(BackgroundQuad(
                rectPts: CGRect(x: indent, y: 0, width: max(0, contentWidth - indent), height: blockHeight),
                color: .codeBackground
            ))
        default:
            blockHeight = shaped.heightPts + padding * 2
        }

        // Quote gutter bars, one per nesting level. A bar extends down across
        // the inter-block gap when the NEXT block is quoted at least as deep —
        // adjacent quoted blocks read as one continuous quote.
        if block.quoteDepth > 0 {
            let nextIndex = index + 1
            for level in 0..<block.quoteDepth {
                var barHeight = blockHeight
                if nextIndex < document.blocks.count {
                    let next = document.blocks[nextIndex]
                    if next.quoteDepth > level {
                        barHeight += spacingAfter(block.kind, metrics: metrics)
                            + spacingBefore(next.kind, metrics: metrics)
                    }
                }
                backgrounds.insert(BackgroundQuad(
                    rectPts: CGRect(
                        x: CGFloat(level) * metrics.indentWidth + 2, y: 0,
                        width: 3, height: barHeight
                    ),
                    color: .quoteBar
                ), at: 0)
            }
        }

        cache[index] = CachedBlock(
            shaped: shaped,
            blockHeightPts: blockHeight,
            textInsetPts: CGPoint(x: indent + padding, y: padding),
            backgrounds: backgrounds
        )
        let composite = compositeHeight(index: index, blockHeight: blockHeight)
        return CGFloat(tree.setExact(index, height: Double(composite)))
    }

    /// Swap a block's styled runs (async syntax highlighting). The text and
    /// fonts must be identical — only colors may differ — so the cached exact
    /// height stays valid; the block just re-shapes on its next frame.
    public func replaceRuns(at index: Int, with runs: [StyledRun]) {
        guard document.blocks.indices.contains(index) else { return }
        document.blocks[index].runs = runs
        cache.removeValue(forKey: index)
    }

    private func compositeHeight(index: Int, blockHeight: CGFloat) -> CGFloat {
        let kind = document.blocks[index].kind
        let before = index == 0 ? 0 : spacingBefore(kind, metrics: metrics)
        return before + blockHeight + spacingAfter(kind, metrics: metrics)
    }

    // MARK: - Queries

    /// Blocks intersecting `docRange`, positioned. Blocks must have been
    /// prepared; anything still estimated is shaped on demand (no anchoring —
    /// use prepare() first for anchored corrections).
    public func placedBlocks(in docRange: Range<CGFloat>) -> [BlockLayout] {
        guard blockCount > 0 else { return [] }
        var placed: [BlockLayout] = []
        var index = tree.blockIndex(at: Double(docRange.lowerBound))
        var y = CGFloat(tree.yOffset(of: index))
        while index < blockCount, y < docRange.upperBound {
            placed.append(placedBlock(index: index, compositeTop: y))
            y += CGFloat(tree.height(of: index))
            index += 1
        }
        return placed
    }

    /// A single positioned block (hit testing); shapes on demand.
    public func placedBlock(at index: Int) -> BlockLayout {
        placedBlock(index: index, compositeTop: CGFloat(tree.yOffset(of: index)))
    }

    private func placedBlock(index: Int, compositeTop: CGFloat) -> BlockLayout {
        if cache[index] == nil || !tree.isExact(index) {
            _ = shapeExact(index)
        }
        let cached = cache[index]!
        let block = document.blocks[index]
        let before = index == 0 ? 0 : spacingBefore(block.kind, metrics: metrics)
        return BlockLayout(
            flatIndex: index,
            id: block.id,
            kind: block.kind,
            yPts: compositeTop + before,
            heightPts: cached.blockHeightPts,
            textInsetPts: cached.textInsetPts,
            backgrounds: cached.backgrounds,
            shaped: cached.shaped
        )
    }

    public func blockIndex(at y: CGFloat) -> Int {
        tree.blockIndex(at: Double(y))
    }

    /// Composite top of a block (before-spacing included below this y).
    public func yOffset(of index: Int) -> CGFloat {
        CGFloat(tree.yOffset(of: index))
    }

    // MARK: - Lifecycle

    /// Drop shaped blocks far outside the kept range. Exact heights REMAIN in
    /// the geometry tree (better estimates); only ShapedBlockText memory goes.
    public func evict(keeping docRange: Range<CGFloat>) {
        guard cache.count > 64 else { return }
        let lowIndex = tree.blockIndex(at: Double(docRange.lowerBound))
        let highIndex = tree.blockIndex(at: Double(docRange.upperBound))
        for key in cache.keys where key < lowIndex || key > highIndex {
            cache.removeValue(forKey: key)
        }
    }

    /// Width or scale changed: shaped blocks are invalid, but their last exact
    /// heights stay as (good) estimates. O(n) flag reset, no re-estimation —
    /// cheap enough for live resize.
    public func reflow(contentWidth: CGFloat, scale: CGFloat) {
        guard contentWidth != self.contentWidth || scale != self.scale else { return }
        self.contentWidth = contentWidth
        self.scale = scale
        cache.removeAll(keepingCapacity: true)
        tree.markAllEstimated()
    }
}
