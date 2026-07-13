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
/// or estimates would be biased by construction. Table rows butt together
/// (separators live inside the row); the table as a whole gets breathing room
/// via its first and last rows.
func spacingBefore(_ block: FlatBlock, metrics: Metrics) -> CGFloat {
    if block.isContinuation {
        return 0 // mega-block fragments stack seamlessly
    }
    if let row = block.tableRow {
        return row.rowIndex == 0 ? 10 : 0
    }
    switch block.kind {
    case .heading: return metrics.headingSpacingBefore
    case .rule: return metrics.ruleSpacing
    default: return 0
    }
}

func spacingAfter(_ block: FlatBlock, metrics: Metrics) -> CGFloat {
    if block.continues {
        return 0 // more fragments of the same block follow
    }
    if let row = block.tableRow {
        return row.isLastRow ? 12 : 0
    }
    switch block.kind {
    case .heading: return metrics.headingSpacingAfter
    case .paragraph: return metrics.paragraphSpacing
    case .codeBlock: return metrics.codeBlockSpacing
    case .listItem: return metrics.listItemSpacing
    case .tableRow: return 0
    case .rule: return metrics.ruleSpacing
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
    /// Column widths per table (padding included), measured once from a
    /// sample of rows; cleared on reflow.
    private var tableWidths: [Int: [CGFloat]] = [:]

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
            } else if block.tableRow != nil {
                // Rows are usually one line tall; exact shaping corrects.
                blockHeight = slotHeight + metrics.tableCellPadding.height * 2
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

            return Double(spacingBefore(block, metrics: metrics) + blockHeight
                + spacingAfter(block, metrics: metrics))
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
        if block.tableRow != nil {
            return shapeTableRowExact(index)
        }
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

        appendQuoteBars(for: block, at: index, blockHeight: blockHeight, into: &backgrounds)

        cache[index] = CachedBlock(
            shaped: shaped,
            blockHeightPts: blockHeight,
            textInsetPts: CGPoint(x: indent + padding, y: padding),
            backgrounds: backgrounds
        )
        let composite = compositeHeight(index: index, blockHeight: blockHeight)
        return CGFloat(tree.setExact(index, height: Double(composite)))
    }

    private func shapeTableRowExact(_ index: Int) -> CGFloat {
        let block = document.blocks[index]
        let info = block.tableRow!
        let table = document.tables[info.tableIndex]
        let indent = CGFloat(block.indentLevel) * metrics.indentWidth
        let widths = columnWidths(
            tableIndex: info.tableIndex, available: max(80, contentWidth - indent)
        )
        let shaped = shapeTableRow(
            cells: info.cells,
            alignments: table.alignments,
            columnWidths: widths,
            cellPadding: metrics.tableCellPadding,
            fonts: fonts,
            scale: scale
        )
        let tableWidth = widths.reduce(0, +)

        var backgrounds: [BackgroundQuad] = []
        if info.isHeader {
            backgrounds.append(BackgroundQuad(
                rectPts: CGRect(x: indent, y: 0, width: tableWidth, height: shaped.heightPts),
                color: .codeBackground
            ))
        }
        // Row separator along the bottom edge.
        backgrounds.append(BackgroundQuad(
            rectPts: CGRect(x: indent, y: shaped.heightPts - 1, width: tableWidth, height: 1),
            color: .rule
        ))
        appendQuoteBars(for: block, at: index, blockHeight: shaped.heightPts, into: &backgrounds)

        cache[index] = CachedBlock(
            shaped: shaped,
            blockHeightPts: shaped.heightPts,
            textInsetPts: CGPoint(x: indent, y: 0),
            backgrounds: backgrounds
        )
        let composite = compositeHeight(index: index, blockHeight: shaped.heightPts)
        return CGFloat(tree.setExact(index, height: Double(composite)))
    }

    /// Quote gutter bars, one per nesting level. A bar extends down across
    /// the inter-block gap when the NEXT block is quoted at least as deep —
    /// adjacent quoted blocks read as one continuous quote.
    private func appendQuoteBars(
        for block: FlatBlock, at index: Int, blockHeight: CGFloat,
        into backgrounds: inout [BackgroundQuad]
    ) {
        guard block.quoteDepth > 0 else { return }
        let nextIndex = index + 1
        for level in 0..<block.quoteDepth {
            var barHeight = blockHeight
            if nextIndex < document.blocks.count {
                let next = document.blocks[nextIndex]
                if next.quoteDepth > level {
                    barHeight += spacingAfter(block, metrics: metrics)
                        + spacingBefore(next, metrics: metrics)
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

    // MARK: - Table columns

    /// Column widths for a table (cell padding included), from min/max-content
    /// measurement of a bounded row sample distributed into the available
    /// width. Measured once; a 10k-row table costs 64 rows of measuring.
    private func columnWidths(tableIndex: Int, available: CGFloat) -> [CGFloat] {
        if let cached = tableWidths[tableIndex] {
            return cached
        }
        let table = document.tables[tableIndex]
        let first = table.firstRowFlatIndex
        let sampleCount = min(table.rowCount, 64)
        let columnCount = max(
            document.blocks.indices.contains(first)
                ? document.blocks[first].tableRow?.cells.count ?? 0 : 0,
            table.alignments.count, 1
        )

        var minContent = [CGFloat](repeating: 8, count: columnCount)
        var maxContent = [CGFloat](repeating: 8, count: columnCount)
        for offset in 0..<sampleCount {
            guard document.blocks.indices.contains(first + offset),
                  let info = document.blocks[first + offset].tableRow else { continue }
            for (column, runs) in info.cells.enumerated() where column < columnCount {
                let (narrow, wide) = intrinsicWidths(of: runs)
                minContent[column] = max(minContent[column], narrow)
                maxContent[column] = max(maxContent[column], wide)
            }
        }

        let pad = metrics.tableCellPadding.width * 2
        let maxTotal = maxContent.reduce(0) { $0 + $1 + pad }
        var widths: [CGFloat]
        if maxTotal <= available {
            // Everything fits unwrapped: columns take their natural width.
            widths = maxContent.map { $0 + pad }
        } else {
            let minTotal = minContent.reduce(0) { $0 + $1 + pad }
            if minTotal >= available {
                // Not even min-content fits: squeeze proportionally (cells
                // will wrap mid-word via forced breaks).
                let squeeze = available / max(minTotal, 1)
                widths = minContent.map { ($0 + pad) * squeeze }
            } else {
                // Start at min-content, grow each column proportionally to its
                // flexibility (max − min) — the classic auto distribution.
                let flex = zip(maxContent, minContent).map { max(0, $0 - $1) }
                let flexTotal = flex.reduce(0, +)
                let extra = available - minTotal
                widths = (0..<columnCount).map { column in
                    minContent[column] + pad + (flexTotal > 0
                        ? extra * flex[column] / flexTotal
                        : extra / CGFloat(columnCount))
                }
            }
        }
        tableWidths[tableIndex] = widths
        return widths
    }

    /// (min-content, max-content) of one cell: longest unbreakable word, and
    /// the full unwrapped width.
    private func intrinsicWidths(of runs: [StyledRun]) -> (CGFloat, CGFloat) {
        let unwrapped = shapeRuns(
            runs, baseFontClass: .body, fonts: fonts, width: 100_000, scale: scale
        )
        let maxContent = unwrapped.lines.map(\.widthPts).max() ?? 0

        let text = runs.map(\.text).joined()
        var minContent: CGFloat = 0
        if let longestWord = text.split(whereSeparator: \.isWhitespace).max(by: { $0.count < $1.count }) {
            let word = shapeRuns(
                [StyledRun(text: String(longestWord), traits: runs.first?.traits ?? [], color: .text)],
                baseFontClass: .body, fonts: fonts, width: 100_000, scale: scale
            )
            minContent = word.lines.first?.widthPts ?? 0
        }
        return (min(minContent, maxContent), maxContent)
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
        let block = document.blocks[index]
        let before = index == 0 ? 0 : spacingBefore(block, metrics: metrics)
        return before + blockHeight + spacingAfter(block, metrics: metrics)
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
        let before = index == 0 ? 0 : spacingBefore(block, metrics: metrics)
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
        tableWidths.removeAll()
        tree.markAllEstimated()
    }
}
