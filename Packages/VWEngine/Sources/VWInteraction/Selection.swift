import CoreText
import Foundation
import VWCore
import VWLayout
import VWStyle
import VWText

// Selection over the flattened document. Positions are TextPosition
// (flat block index + UTF-16 offset into that block's shaped text). Geometry
// comes from retained CTLines; text comes from FlatBlock runs, so copying
// never requires shaping — ⌘A + ⌘C on a 100MB document touches no glyphs.

public struct DocumentSelection: Sendable, Equatable {
    public var anchor: TextPosition
    public var focus: TextPosition

    public init(anchor: TextPosition, focus: TextPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    public init(caret: TextPosition) {
        self.anchor = caret
        self.focus = caret
    }

    public var start: TextPosition { min(anchor, focus) }
    public var end: TextPosition { max(anchor, focus) }
    public var isEmpty: Bool { anchor == focus }
}

// MARK: - Hit testing

/// Document point → text position within a placed block. Points above the
/// text map to its start, below to its end — standard drag semantics.
public func textPosition(
    at docPoint: CGPoint, in block: BlockLayout, contentOriginX: CGFloat = 0
) -> TextPosition {
    let shaped = block.shaped
    guard !shaped.lines.isEmpty else {
        return TextPosition(blockIndex: block.flatIndex, utf16Offset: 0)
    }

    let localY = docPoint.y - block.yPts - block.textInsetPts.y
    let localX = docPoint.x - contentOriginX - block.textInsetPts.x

    if localY < 0 {
        return TextPosition(blockIndex: block.flatIndex, utf16Offset: 0)
    }
    if localY >= CGFloat(shaped.lines.count) * shaped.lineHeightPts {
        return TextPosition(blockIndex: block.flatIndex, utf16Offset: shaped.utf16Length)
    }
    let lineIndex = min(Int(localY / max(shaped.lineHeightPts, 1)), shaped.lines.count - 1)
    let line = shaped.lines[lineIndex]
    let utf16 = CTLineGetStringIndexForPosition(line.ctLine.line, CGPoint(x: localX, y: 0))
    if utf16 == kCFNotFound {
        return TextPosition(blockIndex: block.flatIndex, utf16Offset: line.utf16Range.location)
    }
    return TextPosition(blockIndex: block.flatIndex, utf16Offset: utf16)
}

// MARK: - Selection geometry

/// Selection rectangles for one placed block, in document-space points.
/// `contentOriginX` is the content column's x so callers get absolute rects.
public func selectionRects(
    selection: DocumentSelection, block: BlockLayout, contentOriginX: CGFloat = 0
) -> [CGRect] {
    let start = selection.start
    let end = selection.end
    guard !selection.isEmpty,
          block.flatIndex >= start.blockIndex, block.flatIndex <= end.blockIndex
    else { return [] }

    let shaped = block.shaped
    guard !shaped.lines.isEmpty else { return [] }

    let selStart = block.flatIndex == start.blockIndex ? start.utf16Offset : 0
    let selEnd = block.flatIndex == end.blockIndex ? end.utf16Offset : shaped.utf16Length
    guard selEnd > selStart else { return [] }

    var rects: [CGRect] = []
    for (lineIndex, line) in shaped.lines.enumerated() {
        let lineStart = line.utf16Range.location
        let lineEnd = lineStart + line.utf16Range.length
        let overlapStart = max(selStart, lineStart)
        let overlapEnd = min(selEnd, lineEnd)
        guard overlapEnd > overlapStart else { continue }

        let x0 = CGFloat(CTLineGetOffsetForStringIndex(line.ctLine.line, overlapStart, nil))
        // Selection running past this line's end highlights the whole line
        // (including the space the wrap consumed) — matches system behavior.
        let x1 = overlapEnd >= lineEnd && selEnd > lineEnd
            ? line.widthPts
            : CGFloat(CTLineGetOffsetForStringIndex(line.ctLine.line, overlapEnd, nil))
        guard x1 > x0 else { continue }

        rects.append(CGRect(
            x: contentOriginX + block.textInsetPts.x + x0,
            y: block.yPts + block.textInsetPts.y + CGFloat(lineIndex) * shaped.lineHeightPts,
            width: x1 - x0,
            height: shaped.lineHeightPts
        ))
    }
    return rects
}

// MARK: - Expansion (double/triple click)

/// UTF-16 range of the word around `offset` in `text`; falls back to the
/// whitespace/symbol run when the point isn't inside a word.
public func wordRange(in text: String, aroundUTF16 offset: Int) -> (location: Int, length: Int) {
    let ns = text as NSString
    guard ns.length > 0 else { return (0, 0) }
    let clamped = min(max(offset, 0), ns.length - 1)

    var found: NSRange = NSRange(location: clamped, length: 0)
    var hit = false
    // Enumerate only a small neighborhood — blocks can be megabytes (code).
    let windowStart = max(0, clamped - 256)
    let window = NSRange(location: windowStart, length: min(ns.length - windowStart, 512))
    (text as NSString).enumerateSubstrings(in: window, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
        if NSLocationInRange(clamped, range) {
            found = range
            hit = true
            stop.pointee = true
        }
    }
    if hit { return (found.location, found.length) }

    // Between words: select the contiguous non-word gap.
    let separators = CharacterSet.alphanumerics.inverted
    var lo = clamped
    var hi = clamped + 1
    while lo > 0,
          let scalar = Unicode.Scalar(ns.character(at: lo - 1)), separators.contains(scalar) {
        lo -= 1
    }
    while hi < ns.length,
          let scalar = Unicode.Scalar(ns.character(at: hi)), separators.contains(scalar) {
        hi += 1
    }
    return (lo, max(1, hi - lo))
}

// MARK: - Copy

/// Plain-text of the selection, straight from FlatBlock runs (no shaping).
/// Blocks join with newlines.
public func selectedPlainText(
    selection: DocumentSelection, document: FlatDocument
) -> String {
    let start = selection.start
    let end = selection.end
    guard !selection.isEmpty, start.blockIndex < document.blocks.count else { return "" }

    var parts: [String] = []
    for index in start.blockIndex...min(end.blockIndex, document.blocks.count - 1) {
        let text = document.blocks[index].runs.map(\.text).joined()
        let ns = text as NSString
        let from = index == start.blockIndex ? min(start.utf16Offset, ns.length) : 0
        let to = index == end.blockIndex ? min(end.utf16Offset, ns.length) : ns.length
        guard to > from else {
            parts.append("")
            continue
        }
        parts.append(ns.substring(with: NSRange(location: from, length: to - from)))
    }
    return parts.joined(separator: "\n")
}

/// Byte range into the ORIGINAL markdown source covering the selection — the
/// SourceSpans earning their keep. Whole-block selections take the block's
/// span (markdown syntax included); partial selections map through run spans,
/// byte-exact via UTF-8 prefix length.
public func selectedSourceByteRange(
    selection: DocumentSelection, document: FlatDocument
) -> SourceSpan? {
    let start = selection.start
    let end = selection.end
    guard !selection.isEmpty, start.blockIndex < document.blocks.count else { return nil }

    let startBlock = document.blocks[start.blockIndex]
    let endBlock = document.blocks[min(end.blockIndex, document.blocks.count - 1)]

    let startByte = start.utf16Offset == 0
        ? startBlock.span.startUTF8
        : byteOffset(in: startBlock, atUTF16: start.utf16Offset) ?? startBlock.span.startUTF8
    let endText = endBlock.runs.map(\.text).joined() as NSString
    let endByte = end.utf16Offset >= endText.length
        ? endBlock.span.endUTF8
        : byteOffset(in: endBlock, atUTF16: end.utf16Offset) ?? endBlock.span.endUTF8

    guard endByte > startByte else { return nil }
    return SourceSpan(startUTF8: startByte, endUTF8: endByte)
}

/// Map a UTF-16 offset in a block's rendered text to a source byte offset:
/// find the styled run containing it, then count the UTF-8 bytes of the run
/// prefix (exact for literal text nodes, which is what runs are).
private func byteOffset(in block: FlatBlock, atUTF16 offset: Int) -> Int? {
    var consumed = 0
    for run in block.runs {
        let length = (run.text as NSString).length
        if offset <= consumed + length {
            guard let span = run.span else { return nil }
            let within = offset - consumed
            let prefix = (run.text as NSString).substring(to: max(0, within))
            return span.startUTF8 + prefix.utf8.count
        }
        consumed += length
    }
    return nil
}
