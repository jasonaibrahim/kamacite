import CoreGraphics
import CoreText
import Foundation
import Testing
import VWCore
import VWLayout
import VWParse
import VWStyle
@testable import VWInteraction

@Suite struct SelectionTests {
    private let theme = Theme.light

    @MainActor
    private func layoutFor(_ markdown: String) -> (DocumentLayout, FlatDocument) {
        let flat = flatten(parseMarkdown(markdown))
        let layout = layoutDocument(
            flat, fonts: FontTable(metrics: theme.metrics), metrics: theme.metrics,
            contentWidth: 600, scale: 2
        )
        return (layout, flat)
    }

    @Test @MainActor func hitTestRoundTripsThroughCaretOffsets() {
        let (layout, _) = layoutFor("The quick brown fox jumps over the lazy dog.")
        let block = layout.blocks[0]
        let line = block.shaped.lines[0]

        for offset in [0, 4, 10, 20, 44] {
            let x = CGFloat(CTLineGetOffsetForStringIndex(line.ctLine.line, offset, nil))
            let point = CGPoint(
                x: block.textInsetPts.x + x + 0.5,
                y: block.yPts + block.textInsetPts.y + 2
            )
            let position = textPosition(at: point, in: block)
            #expect(abs(position.utf16Offset - offset) <= 1, "offset \(offset) → \(position.utf16Offset)")
        }
    }

    @Test @MainActor func pointsOutsideTextClampToEnds() {
        let (layout, _) = layoutFor("short paragraph")
        let block = layout.blocks[0]
        let above = textPosition(at: CGPoint(x: 10, y: block.yPts - 50), in: block)
        #expect(above.utf16Offset == 0)
        let below = textPosition(at: CGPoint(x: 10, y: block.yPts + block.heightPts + 50), in: block)
        #expect(below.utf16Offset == block.shaped.utf16Length)
    }

    @Test @MainActor func selectionRectsCoverSelectedLinesOnly() {
        let (layout, _) = layoutFor("""
        A paragraph long enough to wrap across several lines when constrained to a \
        six hundred point content column, which gives multiple lines to select across.
        """)
        let block = layout.blocks[0]
        #expect(block.shaped.lines.count >= 2)

        let selection = DocumentSelection(
            anchor: TextPosition(blockIndex: 0, utf16Offset: 3),
            focus: TextPosition(blockIndex: 0, utf16Offset: block.shaped.lines[0].utf16Range.length + 10)
        )
        let rects = selectionRects(selection: selection, block: block)
        #expect(rects.count == 2)
        // First line's rect runs to the line's full width (selection continues).
        #expect(rects[0].maxX > rects[1].maxX - 600)
        #expect(rects[0].minY < rects[1].minY)
    }

    @Test func wordRangeFindsWords() {
        let range = wordRange(in: "hello brave world", aroundUTF16: 8)
        #expect(range.location == 6)
        #expect(range.length == 5)
    }

    @Test @MainActor func plainTextCopySpansBlocks() {
        let (_, flat) = layoutFor("# Title\n\nFirst para.\n\nSecond para.")
        let lastLength = (flat.blocks[2].runs.map(\.text).joined() as NSString).length
        let selection = DocumentSelection(
            anchor: TextPosition(blockIndex: 0, utf16Offset: 0),
            focus: TextPosition(blockIndex: 2, utf16Offset: lastLength)
        )
        let text = selectedPlainText(selection: selection, document: flat)
        #expect(text == "Title\nFirst para.\nSecond para.")
    }

    @Test @MainActor func sourceCopyIsByteExactThroughMultibyte() {
        let source = "# Café ☕ heading\n\nplain **bold** tail"
        let (_, flat) = layoutFor(source)

        // Whole-document selection → whole-source slice (syntax included).
        let lastLength = (flat.blocks[1].runs.map(\.text).joined() as NSString).length
        let all = DocumentSelection(
            anchor: TextPosition(blockIndex: 0, utf16Offset: 0),
            focus: TextPosition(blockIndex: 1, utf16Offset: lastLength)
        )
        let fullSpan = selectedSourceByteRange(selection: all, document: flat)
        let bytes = Array(source.utf8)
        #expect(fullSpan != nil)
        if let fullSpan {
            let sliced = String(decoding: bytes[fullSpan.startUTF8..<fullSpan.endUTF8], as: UTF8.self)
            #expect(sliced == source)
        }

        // Partial selection inside the bold run: "old" from "bold" — the span
        // must land inside the source's **bold**, after the asterisks and the b.
        let paragraphText = flat.blocks[1].runs.map(\.text).joined() as NSString
        let boldStart = paragraphText.range(of: "bold").location
        let partial = DocumentSelection(
            anchor: TextPosition(blockIndex: 1, utf16Offset: boldStart + 1),
            focus: TextPosition(blockIndex: 1, utf16Offset: boldStart + 4)
        )
        let partialSpan = selectedSourceByteRange(selection: partial, document: flat)
        #expect(partialSpan != nil)
        if let partialSpan {
            let sliced = String(decoding: bytes[partialSpan.startUTF8..<partialSpan.endUTF8], as: UTF8.self)
            #expect(sliced == "old")
        }
    }
}
