import CoreGraphics
import CoreText
import Metal

// Glyph cache: rasterize once per (font, glyph, subpixel bucket, polarity),
// pack into shelf-allocated 1024² texture pages, sample forever. Grayscale
// coverage lives in r8 pages; color emoji in bgra8 pages. A backing-scale
// change flushes everything — glyph bitmaps are scale-specific.
//
// Graduated from the P1 spike (Spikes/TextOnGPU); parity findings in its
// FINDINGS.md. Generational eviction arrives with lazy layout pressure (P3+).

@MainActor
final class GlyphAtlas {
    static let pageSize = 1024
    static let subpixelBuckets = 4

    struct Key: Hashable {
        let fontIndex: Int
        let glyph: CGGlyph
        let bucket: Int
        let isColor: Bool
        /// CoreGraphics adjusts text coverage by polarity: dark-on-light
        /// strokes come out thinner than a white-on-black mask suggests.
        /// Rasterizing each polarity the way CG will composite it gives parity
        /// by construction (P1 measured −14.5 mean luminance bias without).
        let darkOnLight: Bool
    }

    struct Entry {
        let pageIndex: Int
        let isColor: Bool
        let x: Int, y: Int
        let width: Int, height: Int
        /// Add to the glyph's integral pen x to get the quad's left edge.
        let bearingX: Int
        /// Subtract from the baseline y to get the quad's top edge.
        let bearingTop: Int
    }

    @MainActor
    final class Page {
        let texture: MTLTexture
        private var shelves: [(y: Int, height: Int, x: Int)] = []
        private var nextShelfY = 0

        init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: GlyphAtlas.pageSize,
                height: GlyphAtlas.pageSize,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)!
        }

        func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
            guard width <= GlyphAtlas.pageSize else { return nil }
            for i in shelves.indices
            where shelves[i].height >= height && shelves[i].height <= height + 8
                && shelves[i].x + width <= GlyphAtlas.pageSize {
                let slot = (x: shelves[i].x, y: shelves[i].y)
                shelves[i].x += width
                return slot
            }
            let shelfHeight = (height + 3) & ~3
            guard nextShelfY + shelfHeight <= GlyphAtlas.pageSize else { return nil }
            shelves.append((y: nextShelfY, height: shelfHeight, x: width))
            let slot = (x: 0, y: nextShelfY)
            nextShelfY += shelfHeight
            return slot
        }
    }

    private let device: MTLDevice
    private(set) var scale: CGFloat
    private(set) var grayPages: [Page] = []
    private(set) var colorPages: [Page] = []
    private(set) var rasterizedCount = 0
    private var fonts: [CTFont] = []
    /// nil = glyph has no ink (spaces, newlines); cached to skip re-measuring.
    private var entries: [Key: Entry?] = [:]

    init(device: MTLDevice, scale: CGFloat) {
        self.device = device
        self.scale = scale
    }

    /// Drop every entry and page. Called on backingScaleFactor change: bitmaps
    /// rasterized at the old scale are wrong at the new one, never blurry-scaled.
    func flush(scale newScale: CGFloat) {
        scale = newScale
        entries.removeAll()
        grayPages.removeAll()
        colorPages.removeAll()
        rasterizedCount = 0
    }

    func fontIndex(for font: CTFont) -> Int {
        if let index = fonts.firstIndex(where: { CFEqual($0, font) }) {
            return index
        }
        fonts.append(font)
        return fonts.count - 1
    }

    func entry(fontIndex: Int, glyph: CGGlyph, bucket: Int, isColor: Bool, darkOnLight: Bool) -> Entry? {
        let key = Key(
            fontIndex: fontIndex, glyph: glyph, bucket: isColor ? 0 : bucket,
            isColor: isColor, darkOnLight: !isColor && darkOnLight
        )
        if let cached = entries[key] {
            return cached
        }
        let entry = rasterize(
            font: fonts[fontIndex], glyph: glyph, bucket: key.bucket,
            isColor: isColor, darkOnLight: key.darkOnLight
        )
        entries[key] = entry
        return entry
    }

    // MARK: - Rasterization

    private func rasterize(
        font: CTFont, glyph: CGGlyph, bucket: Int, isColor: Bool, darkOnLight: Bool
    ) -> Entry? {
        var g = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &g, &bounds, 1)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let fraction = CGFloat(bucket) / CGFloat(Self.subpixelBuckets)
        let pad = 1
        // Device-pixel ink bounds, y-up relative to the glyph origin.
        let left = Int((bounds.minX * scale).rounded(.down)) - pad
        let bottom = Int((bounds.minY * scale).rounded(.down)) - pad
        let right = Int((bounds.maxX * scale + fraction).rounded(.up)) + pad
        let top = Int((bounds.maxY * scale).rounded(.up)) + pad
        let width = right - left
        let height = top - bottom

        let bytesPerPixel = isColor ? 4 : 1
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: isColor
                ? CGColorSpace(name: CGColorSpace.sRGB)!
                : CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
            bitmapInfo: isColor
                ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                : CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        // Stem darkening, as AppKit applies to text; without it strokes render
        // visibly thinner than native controls.
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)
        // Let CoreText place ink at the fractional offset instead of snapping
        // to the pixel grid — the whole point of the subpixel buckets.
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)

        if !isColor {
            if darkOnLight {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(CGColor(gray: 0, alpha: 1))
            } else {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
            }
        }
        context.scaleBy(x: scale, y: scale)
        var position = CGPoint(
            x: (CGFloat(-left) + fraction) / scale,
            y: CGFloat(-bottom) / scale
        )
        CTFontDrawGlyphs(font, &g, &position, 1, context)

        if darkOnLight, !isColor, let data = context.data {
            let buffer = data.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(width * height) {
                buffer[i] = 255 &- buffer[i]
            }
        }

        guard let slot = allocateSlot(width: width, height: height, isColor: isColor) else {
            return nil // glyph larger than a page
        }
        slot.page.texture.replace(
            region: MTLRegionMake2D(slot.x, slot.y, width, height),
            mipmapLevel: 0,
            withBytes: context.data!,
            bytesPerRow: width * bytesPerPixel
        )
        rasterizedCount += 1

        return Entry(
            pageIndex: slot.pageIndex,
            isColor: isColor,
            x: slot.x, y: slot.y,
            width: width, height: height,
            bearingX: left,
            bearingTop: top
        )
    }

    private func allocateSlot(
        width: Int, height: Int, isColor: Bool
    ) -> (page: Page, pageIndex: Int, x: Int, y: Int)? {
        let pages = isColor ? colorPages : grayPages
        if let last = pages.last, let slot = last.allocate(width: width, height: height) {
            return (last, pages.count - 1, slot.x, slot.y)
        }
        let page = Page(device: device, pixelFormat: isColor ? .bgra8Unorm : .r8Unorm)
        guard let slot = page.allocate(width: width, height: height) else { return nil }
        if isColor {
            colorPages.append(page)
            return (page, colorPages.count - 1, slot.x, slot.y)
        } else {
            grayPages.append(page)
            return (page, grayPages.count - 1, slot.x, slot.y)
        }
    }
}
