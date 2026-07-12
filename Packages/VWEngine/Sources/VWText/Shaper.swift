import CoreText
import Foundation
import VWCore
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

public struct ShapedBlockText: Sendable {
    public let lines: [ShapedTextLine]
    public let lineHeightPts: CGFloat
    /// The exact string the block was shaped from (concatenated styled runs) —
    /// the coordinate space of every UTF-16 offset below, and what selection
    /// copies. Retained for every laid-out block; the lazy store bounds it to
    /// the viewport window.
    public let text: String

    public var heightPts: CGFloat { CGFloat(lines.count) * lineHeightPts }
    public var utf16Length: Int { lines.last.map { $0.utf16Range.location + $0.utf16Range.length } ?? 0 }

    public static let empty = ShapedBlockText(lines: [], lineHeightPts: 0, text: "")

    public init(lines: [ShapedTextLine], lineHeightPts: CGFloat, text: String) {
        self.lines = lines
        self.lineHeightPts = lineHeightPts
        self.text = text
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
    /// Baseline in device pixels from the block-text top, whole-pixel.
    public let baselineDev: CGFloat
    public let runs: [ShapedGlyphRun]
    /// Non-glyph ink (strikethrough segments), points, block-text-relative.
    public let decorations: [LineDecoration]
    /// Retained for caret math: CTLineGetStringIndexForPosition /
    /// CTLineGetOffsetForStringIndex, in the block string's UTF-16 space.
    public let ctLine: LineRef
    /// This line's slice of the block string (UTF-16 location/length).
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
    /// Glyph origins in device pixels relative to the block-text origin:
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

public func shapeBlock(
    _ block: FlatBlock, fonts: FontTable, width: CGFloat, scale: CGFloat
) -> ShapedBlockText {
    let attributed = NSMutableAttributedString()
    for (index, run) in block.runs.enumerated() where !run.text.isEmpty {
        attributed.append(NSAttributedString(string: run.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):
                fonts.font(for: block.baseFontClass, traits: run.traits),
            runIndexKey: NSNumber(value: index),
        ]))
    }
    guard attributed.length > 0 else { return .empty }

    let slot = fonts.lineSlot(for: block.baseFontClass)
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let usableWidth = Double(max(width, 40))

    var lines: [ShapedTextLine] = []
    var start = 0
    let length = attributed.length

    while start < length {
        let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, usableWidth))
        let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
        let baselinePts = CGFloat(lines.count) * slot.height + slot.ascent
        lines.append(extractLine(
            ctLine, block: block, baselinePts: baselinePts, scale: scale,
            utf16Range: (start, count)
        ))
        start += count
    }

    return ShapedBlockText(lines: lines, lineHeightPts: slot.height, text: attributed.string)
}

private func extractLine(
    _ ctLine: CTLine, block: FlatBlock, baselinePts: CGFloat, scale: CGFloat,
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
        let styled = styledRun(for: ctRun, in: block)

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

private func styledRun(for ctRun: CTRun, in block: FlatBlock) -> StyledRun? {
    guard let value = runAttribute(ctRun, key: "vw.run" as CFString) else { return nil }
    let index = unsafeBitCast(value, to: NSNumber.self).intValue
    guard block.runs.indices.contains(index) else { return nil }
    return block.runs[index]
}

private func runAttribute(_ run: CTRun, key: CFString) -> UnsafeRawPointer? {
    let attributes = CTRunGetAttributes(run)
    return CFDictionaryGetValue(attributes, Unmanaged.passUnretained(key).toOpaque())
}
