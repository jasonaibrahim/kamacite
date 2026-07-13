import CoreGraphics
import CoreText
import Foundation
import Testing
import VWCore
import VWLayout
import VWParse
import VWStyle
@testable import VWInteraction

private func sliceBytes(_ source: String, _ span: SourceSpan) -> String {
    let bytes = Array(source.utf8)
    return String(decoding: bytes[span.startUTF8..<min(span.endUTF8, bytes.count)], as: UTF8.self)
}

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

    @Test @MainActor func partialSourceCopyInsidePlainCodeBlock() {
        let source = "intro paragraph\n\n```\nlet answer = compute(42)\nreturn answer\n```"
        let (_, flat) = layoutFor(source)
        let codeIndex = flat.blocks.firstIndex { $0.kind == .codeBlock }!
        let codeText = flat.blocks[codeIndex].runs.map(\.text).joined() as NSString

        // Select "compute(42)" inside the block.
        let target = codeText.range(of: "compute(42)")
        let selection = DocumentSelection(
            anchor: TextPosition(blockIndex: codeIndex, utf16Offset: target.location),
            focus: TextPosition(blockIndex: codeIndex, utf16Offset: target.location + target.length)
        )
        let span = selectedSourceByteRange(selection: selection, document: flat)
        #expect(span != nil)
        if let span {
            #expect(sliceBytes(source, span) == "compute(42)")
        }

        // Selecting from content offset 0 partially: still content, no fence.
        let head = DocumentSelection(
            anchor: TextPosition(blockIndex: codeIndex, utf16Offset: 0),
            focus: TextPosition(blockIndex: codeIndex, utf16Offset: 3)
        )
        if let headSpan = selectedSourceByteRange(selection: head, document: flat) {
            #expect(sliceBytes(source, headSpan) == "let")
        } else {
            Issue.record("no span for head selection")
        }

        // The FULL block still copies with fences included.
        let full = DocumentSelection(
            anchor: TextPosition(blockIndex: codeIndex, utf16Offset: 0),
            focus: TextPosition(blockIndex: codeIndex, utf16Offset: codeText.length)
        )
        if let fullSpan = selectedSourceByteRange(selection: full, document: flat) {
            #expect(sliceBytes(source, fullSpan).hasPrefix("```"))
            #expect(sliceBytes(source, fullSpan).hasSuffix("```"))
        }
    }

    @Test @MainActor func partialSourceCopyInsideHighlightedCodeBlock() {
        let source = "# Título é\n\n```swift\nlet café = greet(\"🚀\")\nreturn café\n```"
        var flat = flatten(parseMarkdown(source))
        let codeIndex = flat.blocks.firstIndex { $0.kind == .codeBlock }!

        // Apply highlighting exactly as the session does (content span rides in).
        let plain = flat.blocks[codeIndex].runs[0]
        let highlighted = highlightCode(plain.text, language: "swift", contentSpan: plain.span)!
        flat.blocks[codeIndex].runs = highlighted

        let codeText = flat.blocks[codeIndex].runs.map(\.text).joined() as NSString
        let target = codeText.range(of: "greet(\"🚀\")")
        let selection = DocumentSelection(
            anchor: TextPosition(blockIndex: codeIndex, utf16Offset: target.location),
            focus: TextPosition(blockIndex: codeIndex, utf16Offset: target.location + target.length)
        )
        let span = selectedSourceByteRange(selection: selection, document: flat)
        #expect(span != nil)
        if let span {
            #expect(sliceBytes(source, span) == "greet(\"🚀\")")
        }

        // A selection crossing token boundaries mid-token stays exact too.
        let mid = codeText.range(of: "afé = gre")
        let crossing = DocumentSelection(
            anchor: TextPosition(blockIndex: codeIndex, utf16Offset: mid.location),
            focus: TextPosition(blockIndex: codeIndex, utf16Offset: mid.location + mid.length)
        )
        if let crossingSpan = selectedSourceByteRange(selection: crossing, document: flat) {
            #expect(sliceBytes(source, crossingSpan) == "afé = gre")
        } else {
            Issue.record("no span for crossing selection")
        }
    }
}
