import CoreText
import Foundation
import VWCore
import VWParse
import VWStyle

// CoreText shaping of one FlatBlock. A custom `vw.run` attribute rides through
// typesetting so styled runs (color token, traits) survive CoreText's own run
// splitting for font fallback — the CJK/emoji CTRuns still know which StyledRun
// they came from.
//
// Coordinates: everything leaves here in DEVICE PIXELS relative to the block's
// text origin. Baselines land on whole pixels (vertical rhythm, no y-shimmer);
// x keeps its fraction — the atlas's subpixel buckets absorb it. The line grid
// is fixed per block from its base font, so fallback fonts with taller metrics
// (CJK, emoji) can't create ransom-note line spacing.
//
// Table rows hold one shaped flow PER CELL; `positionedLines` flattens either
// shape into a uniform list so the renderer and interaction never branch.

public struct ShapedBlockText: Sendable {
    public let lines: [ShapedTextLine]
    public let lineHeightPts: CGFloat
    /// The exact string the block was shaped from — the coordinate space of
    /// every UTF-16 offset below, and what selection copies. For table rows:
    /// cell texts joined with tabs.
    public let text: String
    /// List marker glyphs (bullet/number/checkbox), shaped separately so text
    /// wraps with a hanging indent.
    public let marker: [ShapedGlyphRun]?
    public let markerWidthPts: CGFloat
    /// Table rows only: one shaped flow per cell. When set, `lines` is empty.
    public let cells: [ShapedCell]?
    public let heightPts: CGFloat
    public let utf16Length: Int

    public static let empty = ShapedBlockText(lines: [], lineHeightPts: 0, text: "")

    public init(
        lines: [ShapedTextLine], lineHeightPts: CGFloat, text: String,
        marker: [ShapedGlyphRun]? = nil, markerWidthPts: CGFloat = 0,
        cells: [ShapedCell]? = nil, heightPts: CGFloat? = nil, utf16Length: Int? = nil
    ) {
        self.lines = lines
        self.lineHeightPts = lineHeightPts
        self.text = text
        self.marker = marker
        self.markerWidthPts = markerWidthPts
        self.cells = cells
        self.heightPts = heightPts ?? CGFloat(lines.count) * lineHeightPts
        self.utf16Length = utf16Length
            ?? lines.last.map { $0.utf16Range.location + $0.utf16Range.length } ?? 0
    }
}

/// One table cell's shaped flow, positioned within its row.
public struct ShapedCell: Sendable {
    public let content: ShapedBlockText
    /// Cell CONTENT left edge from the block-text origin, points.
    public let xOffsetPts: CGFloat
    /// Content width — the alignment reference.
    public let widthPts: CGFloat
    /// Content top from the block-text origin (cell padding), points.
    public let contentTopPts: CGFloat
    /// Add to cell-local UTF-16 offsets to get row-text offsets.
    public let utf16Base: Int
    public let alignment: TableAlignment

    public init(
        content: ShapedBlockText, xOffsetPts: CGFloat, widthPts: CGFloat,
        contentTopPts: CGFloat, utf16Base: Int, alignment: TableAlignment
    ) {
        self.content = content
        self.xOffsetPts = xOffsetPts
        self.widthPts = widthPts
        self.contentTopPts = contentTopPts
        self.utf16Base = utf16Base
        self.alignment = alignment
    }

    public func lineXOffset(_ line: ShapedTextLine) -> CGFloat {
        switch alignment {
        case .center: max(0, (widthPts - line.widthPts) / 2)
        case .right: max(0, widthPts - line.widthPts)
        case .left, .none: 0
        }
    }
}

/// A line placed in block-text space — the uniform view over plain blocks and
/// table rows that the renderer and interaction consume.
public struct PositionedLine: Sendable {
    public let line: ShapedTextLine
    /// Add to ctLine-local UTF-16 indices to get block-text offsets.
    public let utf16Base: Int
    /// Line origin x from block-text origin (cell x + alignment shift), points.
    public let xOffsetPts: CGFloat
    /// The flow's top offset (0 for plain blocks, cell padding for cells) —
    /// line.baselineDev already encodes line stacking WITHIN the flow.
    public let flowTopPts: CGFloat
    /// This line's box top in block-text space (hit testing, selection rects).
    public let lineTopPts: CGFloat
    public let lineHeightPts: CGFloat
}

extension ShapedBlockText {
    public var positionedLines: [PositionedLine] {
        guard let cells else {
            return lines.enumerated().map { index, line in
                PositionedLine(
                    line: line, utf16Base: 0, xOffsetPts: 0, flowTopPts: 0,
                    lineTopPts: CGFloat(index) * lineHeightPts,
                    lineHeightPts: lineHeightPts
                )
            }
        }
        var placed: [PositionedLine] = []
        for cell in cells {
            for (index, line) in cell.content.lines.enumerated() {
                placed.append(PositionedLine(
                    line: line,
                    utf16Base: cell.utf16Base,
                    xOffsetPts: cell.xOffsetPts + cell.lineXOffset(line),
                    flowTopPts: cell.contentTopPts,
                    lineTopPts: cell.contentTopPts + CGFloat(index) * cell.content.lineHeightPts,
                    lineHeightPts: cell.content.lineHeightPts
                ))
            }
        }
        return placed
    }
}

/// CTLine is immutable and thread-safe.
public struct LineRef: @unchecked Sendable {
    public let line: CTLine

    public init(_ line: CTLine) {
        self.line = line
    }
}

public struct ShapedTextLine: Sendable {
    /// Baseline in device pixels from its FLOW's top, whole-pixel.
    public let baselineDev: CGFloat
    public let runs: [ShapedGlyphRun]
    /// Non-glyph ink (strikethrough segments), points, flow-relative.
    public let decorations: [LineDecoration]
    /// Retained for caret math, in the flow string's UTF-16 space.
    public let ctLine: LineRef
    /// This line's slice of its flow string (UTF-16 location/length).
    public let utf16Range: (location: Int, length: Int)
    public let widthPts: CGFloat

    public init(
        baselineDev: CGFloat, runs: [ShapedGlyphRun], decorations: [LineDecoration],
        ctLine: LineRef, utf16Range: (location: Int, length: Int), widthPts: CGFloat
    ) {
        self.baselineDev = baselineDev
        self.runs = runs
        self.decorations = decorations
        self.ctLine = ctLine
        self.utf16Range = utf16Range
        self.widthPts = widthPts
    }
}

public struct LineDecoration: Sendable {
    public let rectPts: CGRect
    public let color: ColorToken

    public init(rectPts: CGRect, color: ColorToken) {
        self.rectPts = rectPts
        self.color = color
    }
}

/// One post-fallback CTRun's worth of glyphs. CTFont is immutable/thread-safe.
public struct ShapedGlyphRun: @unchecked Sendable {
    public let font: CTFont
    public let isColorGlyphs: Bool
    public let color: ColorToken
    public let glyphs: [CGGlyph]
    /// Glyph origins in device pixels relative to the flow origin:
    /// x fractional, y = whole-pixel baseline plus any run offset.
    public let positionsDev: [CGPoint]

    public init(font: CTFont, isColorGlyphs: Bool, color: ColorToken, glyphs: [CGGlyph], positionsDev: [CGPoint]) {
        self.font = font
        self.isColorGlyphs = isColorGlyphs
        self.color = color
        self.glyphs = glyphs
        self.positionsDev = positionsDev
    }
}

private let runIndexKey = NSAttributedString.Key("vw.run")

// MARK: - Block shaping

public func shapeBlock(
    _ block: FlatBlock, fonts: FontTable, width: CGFloat, scale: CGFloat
) -> ShapedBlockText {
    let shaped = shapeRuns(
        block.runs, baseFontClass: block.baseFontClass,
        fonts: fonts, width: width, scale: scale
    )
    guard let markerText = block.marker, !markerText.isEmpty,
          let firstLine = shaped.lines.first
    else { return shaped }

    let (markerRuns, markerWidth) = shapeMarker(
        markerText, fonts: fonts, baselineDev: firstLine.baselineDev, scale: scale
    )
    return ShapedBlockText(
        lines: shaped.lines, lineHeightPts: shaped.lineHeightPts, text: shaped.text,
        marker: markerRuns, markerWidthPts: markerWidth
    )
}

/// Shape one run flow wrapped at `width` — the core every path shares.
public func shapeRuns(
    _ runs: [StyledRun], baseFontClass: FontClass,
    fonts: FontTable, width: CGFloat, scale: CGFloat
) -> ShapedBlockText {
    let attributed = NSMutableAttributedString()
    for (index, run) in runs.enumerated() where !run.text.isEmpty {
        attributed.append(NSAttributedString(string: run.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):
                fonts.font(for: baseFontClass, traits: run.traits),
            runIndexKey: NSNumber(value: index),
        ]))
    }
    guard attributed.length > 0 else { return .empty }

    let slot = fonts.lineSlot(for: baseFontClass)
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let usableWidth = Double(max(width, 24))

    var lines: [ShapedTextLine] = []
    var start = 0
    let length = attributed.length

    while start < length {
        let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, usableWidth))
        let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
        let baselinePts = CGFloat(lines.count) * slot.height + slot.ascent
        lines.append(extractLine(
            ctLine, styledRuns: runs, baselinePts: baselinePts, scale: scale,
            utf16Range: (start, count)
        ))
        start += count
    }

    return ShapedBlockText(lines: lines, lineHeightPts: slot.height, text: attributed.string)
}

// MARK: - Table rows

/// Shape a table row: each cell is its own flow wrapped at its column's
/// content width. `columnWidths` INCLUDE the horizontal cell padding.
public func shapeTableRow(
    cells: [[StyledRun]],
    alignments: [TableAlignment],
    columnWidths: [CGFloat],
    cellPadding: CGSize,
    fonts: FontTable,
    scale: CGFloat
) -> ShapedBlockText {
    let slot = fonts.lineSlot(for: .body)
    var shapedCells: [ShapedCell] = []
    var rowText = ""
    var utf16Base = 0
    var columnX: CGFloat = 0
    var maxContentHeight: CGFloat = slot.height

    for (index, cellRuns) in cells.enumerated() {
        let columnWidth = index < columnWidths.count ? columnWidths[index] : 60
        let contentWidth = max(16, columnWidth - cellPadding.width * 2)
        let content = shapeRuns(
            cellRuns, baseFontClass: .body, fonts: fonts, width: contentWidth, scale: scale
        )
        if index > 0 {
            rowText += "\t"
            utf16Base += 1
        }
        shapedCells.append(ShapedCell(
            content: content,
            xOffsetPts: columnX + cellPadding.width,
            widthPts: contentWidth,
            contentTopPts: cellPadding.height,
            utf16Base: utf16Base,
            alignment: index < alignments.count ? alignments[index] : .none
        ))
        rowText += content.text
        utf16Base += content.utf16Length
        columnX += columnWidth
        maxContentHeight = max(maxContentHeight, content.heightPts)
    }

    return ShapedBlockText(
        lines: [], lineHeightPts: slot.height, text: rowText,
        cells: shapedCells,
        heightPts: maxContentHeight + cellPadding.height * 2,
        utf16Length: utf16Base
    )
}

// MARK: - Markers

/// One-line shape of a list marker. Same glyph pipeline as body text, aligned
/// to the first text line's baseline.
private func shapeMarker(
    _ text: String, fonts: FontTable, baselineDev: CGFloat, scale: CGFloat
) -> ([ShapedGlyphRun]?, CGFloat) {
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): fonts.font(for: .body, traits: [])
    ])
    let ctLine = CTLineCreateWithAttributedString(attributed)
    let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))

    var runs: [ShapedGlyphRun] = []
    let runArray = CTLineGetGlyphRuns(ctLine)
    for runIndex in 0..<CFArrayGetCount(runArray) {
        let ctRun = unsafeBitCast(CFArrayGetValueAtIndex(runArray, runIndex), to: CTRun.self)
        let glyphCount = CTRunGetGlyphCount(ctRun)
        guard glyphCount > 0 else { continue }
        var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
        var positions = [CGPoint](repeating: .zero, count: glyphCount)
        CTRunGetGlyphs(ctRun, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(ctRun, CFRange(location: 0, length: 0), &positions)
        let font = runAttribute(ctRun, key: kCTFontAttributeName).map {
            unsafeBitCast($0, to: CTFont.self)
        } ?? CTFontCreateUIFontForLanguage(.system, 15, nil)!
        runs.append(ShapedGlyphRun(
            font: font,
            isColorGlyphs: CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs),
            color: .secondaryText,
            glyphs: glyphs,
            positionsDev: positions.map { CGPoint(x: $0.x * scale, y: baselineDev - $0.y * scale) }
        ))
    }
    return (runs.isEmpty ? nil : runs, width)
}

// MARK: - Extraction

private func extractLine(
    _ ctLine: CTLine, styledRuns: [StyledRun], baselinePts: CGFloat, scale: CGFloat,
    utf16Range: (location: Int, length: Int)
) -> ShapedTextLine {
    let baselineDev = (baselinePts * scale).rounded()
    var runs: [ShapedGlyphRun] = []
    var decorations: [LineDecoration] = []

    let runArray = CTLineGetGlyphRuns(ctLine)
    for runIndex in 0..<CFArrayGetCount(runArray) {
        let ctRun = unsafeBitCast(CFArrayGetValueAtIndex(runArray, runIndex), to: CTRun.self)
        let glyphCount = CTRunGetGlyphCount(ctRun)
        guard glyphCount > 0 else { continue }

        var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
        var linePositions = [CGPoint](repeating: .zero, count: glyphCount)
        CTRunGetGlyphs(ctRun, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(ctRun, CFRange(location: 0, length: 0), &linePositions)

        let font = runAttribute(ctRun, key: kCTFontAttributeName).map {
            unsafeBitCast($0, to: CTFont.self)
        } ?? CTFontCreateUIFontForLanguage(.system, 15, nil)!
        let styled = styledRun(for: ctRun, in: styledRuns)

        let positionsDev = linePositions.map { p in
            CGPoint(x: p.x * scale, y: baselineDev - p.y * scale)
        }
        runs.append(ShapedGlyphRun(
            font: font,
            isColorGlyphs: CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs),
            color: styled?.color ?? .text,
            glyphs: glyphs,
            positionsDev: positionsDev
        ))

        if let styled, styled.traits.contains(.strikethrough) {
            var runWidth = CTRunGetTypographicBounds(ctRun, CFRange(location: 0, length: 0), nil, nil, nil)
            if runWidth <= 0 { runWidth = 1 }
            let xHeight = CTFontGetXHeight(font)
            decorations.append(LineDecoration(
                rectPts: CGRect(
                    x: linePositions[0].x,
                    y: baselinePts - xHeight * 0.55,
                    width: CGFloat(runWidth),
                    height: max(1, CTFontGetUnderlineThickness(font))
                ),
                color: styled.color
            ))
        }
    }

    return ShapedTextLine(
        baselineDev: baselineDev,
        runs: runs,
        decorations: decorations,
        ctLine: LineRef(ctLine),
        utf16Range: utf16Range,
        widthPts: CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
    )
}

private func styledRun(for ctRun: CTRun, in runs: [StyledRun]) -> StyledRun? {
    guard let value = runAttribute(ctRun, key: "vw.run" as CFString) else { return nil }
    let index = unsafeBitCast(value, to: NSNumber.self).intValue
    guard runs.indices.contains(index) else { return nil }
    return runs[index]
}

private func runAttribute(_ run: CTRun, key: CFString) -> UnsafeRawPointer? {
    let attributes = CTRunGetAttributes(run)
    return CFDictionaryGetValue(attributes, Unmanaged.passUnretained(key).toOpaque())
}
