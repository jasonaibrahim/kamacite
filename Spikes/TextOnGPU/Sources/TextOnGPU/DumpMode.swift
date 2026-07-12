import AppKit
import CoreText
import ImageIO
import Metal
import UniformTypeIdentifiers

// Headless verification for the spike's four risks:
//   1. gamma/weight parity  — pixel-diff Metal vs a CoreText reference render
//   2. subpixel stability   — ink mass must stay ~constant under fractional offsets
//   3. emoji                — color pages must produce saturated pixels
//   4. retina flush         — atlas rebuilds cleanly at a new scale
// Writes PNGs for eyeballing and prints machine-checkable stats.

private let canvasWidthPoints: CGFloat = 620

@MainActor
func runDump(outputDirectory: String) throws {
    let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    guard let device = MTLCreateSystemDefaultDevice() else {
        throw SpikeError("no Metal device")
    }
    let renderer = try GlyphRenderer(device: device)
    print("device: \(device.name)")

    var failures: [String] = []

    for theme in [Theme.dark, Theme.light] {
        let scale: CGFloat = 2
        let shaped = shape(SampleText.build(theme: theme), wrapWidth: canvasWidthPoints, scale: scale)
        let width = Int(shaped.size.width), height = Int(shaped.size.height)
        let atlas = GlyphAtlas(device: device, scale: scale)

        let start = CACurrentMediaTime()
        let texture = renderer.renderOffscreen(
            shaped: shaped, atlas: atlas, background: theme.background, width: width, height: height
        )
        let firstFrameMs = (CACurrentMediaTime() - start) * 1000

        let metal = pixels(from: texture)
        let reference = referencePixels(shaped: shaped, theme: theme, width: width, height: height)
        try writePNG(metal, width: width, height: height, to: outputURL.appendingPathComponent("metal-\(theme.name)@2x.png"))
        try writePNG(reference, width: width, height: height, to: outputURL.appendingPathComponent("ref-\(theme.name)@2x.png"))

        let stats = diff(metal: metal, reference: reference, background: sRGBComponents(theme.background))
        try writePNG(stats.image, width: width, height: height, to: outputURL.appendingPathComponent("diff-\(theme.name)@2x.png"))

        print("""
        [\(theme.name)] \(width)×\(height)  atlas: \(atlas.grayPages.count) gray + \(atlas.colorPages.count) color pages, \
        \(atlas.rasterizedCount) glyphs rasterized  first-frame (shape+atlas+encode+wait): \(String(format: "%.1f", firstFrameMs))ms
        [\(theme.name)] ink pixels: \(stats.inkPixels)  mean signed lum diff (metal−ref): \(String(format: "%+.2f", stats.meanSigned))  \
        mean |diff|: \(String(format: "%.2f", stats.meanAbs))  max |diff|: \(stats.maxAbs)  pixels >16/255 off: \(String(format: "%.2f%%", stats.percentOver16))
        """)

        // Weight parity gate: a gamma mistake shows up as a systematic bias of
        // several luminance levels; subpixel-bucket quantization alone stays small.
        if abs(stats.meanSigned) > 6 {
            failures.append("[\(theme.name)] weight bias vs CoreText reference: \(stats.meanSigned)")
        }

        // Emoji gate: saturated color must exist somewhere (gray pipeline can't produce it).
        if !hasSaturatedPixels(metal, width: width, height: height) {
            failures.append("[\(theme.name)] no saturated pixels — color emoji missing")
        }
    }

    // Subpixel sweep: total ink must stay near-constant as everything slides by
    // fractions of a pixel. Snapping-to-grid or broken buckets shows up as
    // multi-percent swings.
    do {
        let theme = Theme.dark
        let scale: CGFloat = 2
        let shaped = shape(SampleText.build(theme: theme), wrapWidth: canvasWidthPoints, scale: scale)
        let width = Int(shaped.size.width), height = Int(shaped.size.height)
        let atlas = GlyphAtlas(device: device, scale: scale)
        let bg = sRGBComponents(theme.background)

        var inkPerOffset: [Double] = []
        for step in 0..<8 {
            let offset = CGPoint(x: CGFloat(step) / 8, y: 0)
            let texture = renderer.renderOffscreen(
                shaped: shaped, atlas: atlas, offset: offset,
                background: theme.background, width: width, height: height
            )
            inkPerOffset.append(inkMass(pixels(from: texture), background: bg))
        }
        let mean = inkPerOffset.reduce(0, +) / Double(inkPerOffset.count)
        let maxDeviation = inkPerOffset.map { abs($0 - mean) / mean * 100 }.max() ?? 0
        let perOffset = inkPerOffset.map { String(format: "%.0f", $0) }.joined(separator: " ")
        print("[subpixel] ink mass at x-offsets 0…7/8 px: \(perOffset)")
        print("[subpixel] max deviation from mean: \(String(format: "%.2f%%", maxDeviation))")
        if maxDeviation > 2 {
            failures.append("[subpixel] ink mass varies \(String(format: "%.2f%%", maxDeviation)) across fractional offsets")
        }

        // Retina flush: same content at 1x after flushing must re-rasterize from zero.
        atlas.flush(scale: 1)
        let shaped1x = shape(SampleText.build(theme: theme), wrapWidth: canvasWidthPoints, scale: 1)
        let w1 = Int(shaped1x.size.width), h1 = Int(shaped1x.size.height)
        let texture1x = renderer.renderOffscreen(
            shaped: shaped1x, atlas: atlas, background: theme.background, width: w1, height: h1
        )
        try writePNG(pixels(from: texture1x), width: w1, height: h1, to: outputURL.appendingPathComponent("metal-dark@1x.png"))
        print("[flush] re-rasterized \(atlas.rasterizedCount) glyphs at 1x into \(atlas.grayPages.count) gray + \(atlas.colorPages.count) color pages (\(w1)×\(h1))")
        if atlas.rasterizedCount == 0 {
            failures.append("[flush] atlas did not re-rasterize after scale change")
        }
    }

    print(failures.isEmpty ? "RESULT: PASS" : "RESULT: FAIL\n - " + failures.joined(separator: "\n - "))
    if !failures.isEmpty {
        throw SpikeError("verification failed")
    }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Pixel plumbing (BGRA8, byteOrder32Little + premultipliedFirst throughout)

private func pixels(from texture: MTLTexture) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    bytes.withUnsafeMutableBytes { raw in
        texture.getBytes(
            raw.baseAddress!, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
        )
    }
    return bytes
}

/// Ground truth: the same shaped CTLines drawn by CoreText itself into a bitmap
/// configured the way AppKit draws text (sRGB, font smoothing, true subpixel
/// positioning — no bucket quantization).
@MainActor
private func referencePixels(shaped: ShapedText, theme: Theme, width: Int, height: Int) -> [UInt8] {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    )!
    context.setFillColor(theme.background)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setAllowsFontSmoothing(true)
    context.setShouldSmoothFonts(true)
    context.setAllowsFontSubpixelPositioning(true)
    context.setShouldSubpixelPositionFonts(true)
    context.setAllowsFontSubpixelQuantization(false)
    context.setShouldSubpixelQuantizeFonts(false)

    context.scaleBy(x: shaped.scale, y: shaped.scale)
    for line in shaped.lines {
        context.textPosition = CGPoint(
            x: line.penX,
            y: (CGFloat(height) - line.baselineY) / shaped.scale
        )
        CTLineDraw(line.ctLine, context)
    }
    let buffer = context.data!
    return [UInt8](UnsafeRawBufferPointer(start: buffer, count: width * height * 4))
}

private struct DiffStats {
    let inkPixels: Int
    let meanSigned: Double
    let meanAbs: Double
    let maxAbs: Int
    let percentOver16: Double
    let image: [UInt8]
}

private func diff(metal: [UInt8], reference: [UInt8], background: SIMD4<Float>) -> DiffStats {
    let bgLum = Double(background.x + background.y + background.z) / 3 * 255
    var image = [UInt8](repeating: 255, count: metal.count)
    var inkPixels = 0
    var signedSum = 0.0, absSum = 0.0
    var maxAbs = 0, over16 = 0

    for p in stride(from: 0, to: metal.count, by: 4) {
        let m = (Double(metal[p]) + Double(metal[p + 1]) + Double(metal[p + 2])) / 3
        let r = (Double(reference[p]) + Double(reference[p + 1]) + Double(reference[p + 2])) / 3
        let delta = m - r
        let isInk = abs(m - bgLum) > 10 || abs(r - bgLum) > 10
        if isInk {
            inkPixels += 1
            signedSum += delta
            absSum += abs(delta)
            maxAbs = max(maxAbs, Int(abs(delta)))
            if abs(delta) > 16 { over16 += 1 }
        }
        // Amplified diff view: mid-gray = equal, dark = metal thinner, light = fatter.
        let g = UInt8(max(0, min(255, 128 + delta * 4)))
        image[p] = g; image[p + 1] = g; image[p + 2] = g; image[p + 3] = 255
    }
    let n = max(1, inkPixels)
    return DiffStats(
        inkPixels: inkPixels,
        meanSigned: signedSum / Double(n),
        meanAbs: absSum / Double(n),
        maxAbs: maxAbs,
        percentOver16: Double(over16) / Double(n) * 100,
        image: image
    )
}

private func inkMass(_ pixels: [UInt8], background: SIMD4<Float>) -> Double {
    let bgLum = Double(background.x + background.y + background.z) / 3 * 255
    var total = 0.0
    for p in stride(from: 0, to: pixels.count, by: 4) {
        let lum = (Double(pixels[p]) + Double(pixels[p + 1]) + Double(pixels[p + 2])) / 3
        total += abs(lum - bgLum)
    }
    return total / 255
}

private func hasSaturatedPixels(_ pixels: [UInt8], width: Int, height: Int) -> Bool {
    var saturated = 0
    for p in stride(from: 0, to: pixels.count, by: 4) {
        let b = Int(pixels[p]), g = Int(pixels[p + 1]), r = Int(pixels[p + 2])
        if max(r, g, b) - min(r, g, b) > 60 { saturated += 1 }
    }
    return saturated > 100
}

private func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
    var data = pixels
    let cgImage = data.withUnsafeMutableBytes { raw -> CGImage? in
        CGContext(
            data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )?.makeImage()
    }
    guard let cgImage,
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw SpikeError("could not encode \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw SpikeError("could not write \(url.lastPathComponent)")
    }
    print("wrote \(url.path)")
}
