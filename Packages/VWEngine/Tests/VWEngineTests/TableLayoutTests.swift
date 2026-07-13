import CoreGraphics
import Foundation
import Testing
import VWCore
import VWInteraction
import VWParse
import VWStyle
@testable import VWLayout

@Suite struct TableLayoutTests {
    private let theme = Theme.light

    @MainActor
    private func lazyLayout(_ markdown: String, width: CGFloat = 600) -> LazyLayout {
        LazyLayout(
            document: flatten(parseMarkdown(markdown)),
            fonts: FontTable(metrics: theme.metrics),
            metrics: theme.metrics, contentWidth: width, scale: 2
        )
    }

    @Test @MainActor func narrowTableTakesNaturalWidths() {
        let layout = lazyLayout("| a | b |\n| --- | --- |\n| xx | yy |")
        layout.prepare(docRange: 0..<10_000, anchorY: 0)
        let rows = layout.placedBlocks(in: 0..<10_000).filter { $0.kind == .tableRow }
        #expect(rows.count == 2)
        guard let cells = rows[0].shaped.cells else {
            Issue.record("expected shaped cells")
            return
        }
        #expect(cells.count == 2)
        // Natural (max-content) columns: table far narrower than the page.
        let tableWidth = cells[1].xOffsetPts + cells[1].widthPts
        #expect(tableWidth < 200)
        // Both rows share identical column positions.
        #expect(rows[1].shaped.cells?[1].xOffsetPts == cells[1].xOffsetPts)
    }

    @Test @MainActor func wideTableDistributesIntoAvailableWidth() {
        let long = String(repeating: "word ", count: 40)
        let layout = lazyLayout("| short | long |\n| --- | --- |\n| a | \(long) |", width: 500)
        layout.prepare(docRange: 0..<10_000, anchorY: 0)
        let rows = layout.placedBlocks(in: 0..<10_000).filter { $0.kind == .tableRow }
        guard let cells = rows[1].shaped.cells else {
            Issue.record("expected cells")
            return
        }
        // Fits the content column, long cell wraps to multiple lines.
        let tableWidth = cells.last!.xOffsetPts + cells.last!.widthPts + theme.metrics.tableCellPadding.width
        #expect(tableWidth <= 501)
        #expect(cells[1].content.lines.count > 1)
        // Row height follows the tallest cell.
        #expect(rows[1].heightPts >= cells[1].content.heightPts)
    }

    @Test @MainActor func alignmentShiftsLines() {
        let layout = lazyLayout("| left | center | right |\n| :-- | :-: | --: |\n| aaaaaaaaaa | b | c |")
        layout.prepare(docRange: 0..<10_000, anchorY: 0)
        let row = layout.placedBlocks(in: 0..<10_000).filter { $0.kind == .tableRow }[1]
        let placed = row.shaped.positionedLines
        guard placed.count == 3 else {
            Issue.record("expected 3 cell lines, got \(placed.count)")
            return
        }
        guard let cells = row.shaped.cells else { return }
        // Center and right cells shift their (narrow) lines inside the column.
        #expect(placed[1].xOffsetPts > cells[1].xOffsetPts)
        #expect(placed[2].xOffsetPts > cells[2].xOffsetPts)
        #expect(abs((placed[2].xOffsetPts + placed[2].line.widthPts) - (cells[2].xOffsetPts + cells[2].widthPts)) < 1)
    }

    @Test @MainActor func tenThousandRowTableStaysViewportLazy() {
        var markdown = "| id | name | value |\n| --- | --- | --- |\n"
        for i in 0..<10_000 {
            markdown += "| \(i) | row-\(i) | \(i * 7) |\n"
        }
        let start = Date()
        let layout = lazyLayout(markdown)
        layout.prepare(docRange: 0..<1600, anchorY: 0)
        let elapsed = Date().timeIntervalSince(start)

        #expect(layout.blockCount == 10_001)
        #expect(layout.shapedBlockCount < 120, "shaped \(layout.shapedBlockCount) rows — not lazy")
        #expect(elapsed < 2.0, "10k-row table took \(elapsed)s")

        // Jump deep into the table: still cheap, still aligned columns.
        let far = layout.contentHeightPts * 0.9
        layout.prepare(docRange: far..<(far + 800), anchorY: far)
        let deepRows = layout.placedBlocks(in: far..<(far + 800)).filter { $0.kind == .tableRow }
        #expect(!deepRows.isEmpty)
        let firstRows = layout.placedBlocks(in: 0..<400).filter { $0.kind == .tableRow }
        #expect(deepRows[0].shaped.cells?[1].xOffsetPts == firstRows[0].shaped.cells?[1].xOffsetPts)
    }

    @Test @MainActor func selectionAndHitTestingWorkInsideCells() {
        let layout = lazyLayout("| alpha | beta |\n| --- | --- |\n| gamma | delta |")
        layout.prepare(docRange: 0..<10_000, anchorY: 0)
        let row = layout.placedBlocks(in: 0..<10_000).filter { $0.kind == .tableRow }[1]
        guard let cells = row.shaped.cells, cells.count == 2 else {
            Issue.record("expected 2 cells")
            return
        }

        // Point in the second cell resolves past the first cell's text + tab.
        let pointInSecondCell = CGPoint(
            x: row.textInsetPts.x + cells[1].xOffsetPts + 2,
            y: row.yPts + row.textInsetPts.y + cells[1].contentTopPts + 2
        )
        let position = textPosition(at: pointInSecondCell, in: row)
        #expect(position.utf16Offset >= cells[1].utf16Base)

        // Selecting the full row yields one rect per cell, not one giant rect.
        let selection = DocumentSelection(
            anchor: TextPosition(blockIndex: row.flatIndex, utf16Offset: 0),
            focus: TextPosition(blockIndex: row.flatIndex, utf16Offset: row.shaped.utf16Length)
        )
        let rects = selectionRects(selection: selection, block: row)
        #expect(rects.count == 2)
        #expect(rects[1].minX > rects[0].maxX)

        // Row text (and copy) is tab-joined.
        #expect(row.shaped.text == "gamma\tdelta")
    }
}
