import AppKit
import CoreText

// CoreText does the hard parts — bidi, arabic joining, font fallback, ligatures,
// emoji ZWJ sequences — during typesetting. We extract the resolved glyphs and
// positions per run; from here down the pipeline never sees characters again.

struct ShapedRun {
    let font: CTFont
    /// True for color-glyph fonts (Apple Color Emoji): rasterized to BGRA pages,
    /// drawn through the color pipeline, no subpixel buckets.
    let isColor: Bool
    let color: CGColor
    let glyphs: [CGGlyph]
    /// Baseline origins in device pixels, absolute in the canvas.
    /// x is fractional (subpixel positioning); y is the rounded baseline.
    let positions: [CGPoint]
}

struct ShapedLine {
    /// Retained for the CoreText reference render (CTLineDraw at the same origin)
    /// and, in the real engine, for caret/hit-test APIs.
    let ctLine: CTLine
    /// Pen origin x in points, for the reference render.
    let penX: CGFloat
    /// Baseline y in device pixels from the canvas top, rounded to a whole pixel.
    let baselineY: CGFloat
    let runs: [ShapedRun]
}

struct ShapedText {
    let lines: [ShapedLine]
    /// Device pixels.
    let size: CGSize
    let scale: CGFloat
}

/// Wrap and shape `text` at `wrapWidth` points, producing device-pixel glyph
/// positions for `scale`. Baselines are rounded to whole device pixels (y);
/// x keeps its fraction — the atlas's subpixel buckets absorb it.
func shape(_ text: NSAttributedString, wrapWidth: CGFloat, scale: CGFloat, inset: CGFloat = 16) -> ShapedText {
    let typesetter = CTTypesetterCreateWithAttributedString(text)
    let length = text.length
    let usableWidth = Double(wrapWidth - inset * 2)

    var lines: [ShapedLine] = []
    var start = 0
    var cursorY = inset // points

    while start < length {
        let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, usableWidth))
        let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)

        let baselineY = ((cursorY + ascent) * scale).rounded()
        var runs: [ShapedRun] = []

        let runArray = CTLineGetGlyphRuns(ctLine)
        for runIndex in 0..<CFArrayGetCount(runArray) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runArray, runIndex), to: CTRun.self)
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }

            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var linePositions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &linePositions)

            let font = runFont(run)
            let positions = linePositions.map { p in
                CGPoint(x: (inset + p.x) * scale, y: baselineY - p.y * scale)
            }
            runs.append(ShapedRun(
                font: font,
                isColor: CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs),
                color: runColor(run),
                glyphs: glyphs,
                positions: positions
            ))
        }

        lines.append(ShapedLine(ctLine: ctLine, penX: inset, baselineY: baselineY, runs: runs))
        cursorY += ascent + descent + leading
        start += count
    }

    return ShapedText(
        lines: lines,
        size: CGSize(width: (wrapWidth * scale).rounded(), height: ((cursorY + inset) * scale).rounded()),
        scale: scale
    )
}

private func runFont(_ run: CTRun) -> CTFont {
    let attributes = CTRunGetAttributes(run)
    let key = Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
    guard let value = CFDictionaryGetValue(attributes, key) else {
        fatalError("CTRun without a font attribute")
    }
    return unsafeBitCast(value, to: CTFont.self)
}

private func runColor(_ run: CTRun) -> CGColor {
    let attributes = CTRunGetAttributes(run)
    let key = Unmanaged.passUnretained(kCTForegroundColorAttributeName).toOpaque()
    guard let value = CFDictionaryGetValue(attributes, key) else {
        return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    }
    return unsafeBitCast(value, to: CGColor.self)
}
