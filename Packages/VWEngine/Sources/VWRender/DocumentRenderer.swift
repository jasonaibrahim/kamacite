import CoreGraphics
import Metal
import VWLayout
import VWStyle
import VWText

// Encodes a DocumentLayout into a Metal render pass: painter's order is
// solids-below (code backgrounds, rules) → gray glyph pages → color glyph
// pages → solids-above (strikethrough). One instanced draw per bucket.

@MainActor
public final class DocumentRenderer {
    /// Matches GlyphInstance in the MSL source (stride 48).
    struct GlyphQuad {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        var color: SIMD4<Float>
    }

    /// Matches SolidInstance in the MSL source (stride 32).
    struct SolidQuad {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var color: SIMD4<Float>
    }

    /// Matches PillInstance in the MSL source (stride 48).
    struct PillQuad {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var color: SIMD4<Float>
        var radius: Float
        var _pad0: Float = 0
        var _pad1: Float = 0
        var _pad2: Float = 0
    }

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let solidPipeline: MTLRenderPipelineState
    private let grayPipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let pillPipeline: MTLRenderPipelineState
    private let atlas: GlyphAtlas

    /// Blocks on RendererCore's warm-up if it hasn't finished — call
    /// RendererCore.shared.warmUp() at process start so it always has.
    public init(scale: CGFloat) throws {
        precondition(MemoryLayout<GlyphQuad>.stride == 48, "GlyphQuad layout diverged from MSL")
        precondition(MemoryLayout<SolidQuad>.stride == 32, "SolidQuad layout diverged from MSL")
        precondition(MemoryLayout<PillQuad>.stride == 48, "PillQuad layout diverged from MSL")
        let core = try RendererCore.shared.pipelines()
        self.device = core.device
        self.commandQueue = core.device.makeCommandQueue()!
        self.atlas = GlyphAtlas(device: core.device, scale: scale)
        self.solidPipeline = core.solid
        self.grayPipeline = core.gray
        self.colorPipeline = core.color
        self.pillPipeline = core.pill
    }

    /// Call on backingScaleFactor change; drops every rasterized glyph.
    public func scaleChanged(_ scale: CGFloat) {
        guard scale != atlas.scale else { return }
        atlas.flush(scale: scale)
    }

    // MARK: - Encoding

    /// A rounded-rect drawn topmost in VIEW space (the overlay scrollbar).
    public struct OverlayPill {
        public var rectPts: CGRect
        public var cornerRadiusPts: CGFloat
        public var color: SIMD4<Float>

        public init(rectPts: CGRect, cornerRadiusPts: CGFloat, color: SIMD4<Float>) {
            self.rectPts = rectPts
            self.cornerRadiusPts = cornerRadiusPts
            self.color = color
        }
    }

    /// Draw `layout` into `target`. `originPts` is the content-column origin in
    /// view space (centering inset minus scroll offset), points.
    /// `selectionRects` are content-column-relative document rects painted
    /// below glyphs (above block backgrounds). `overlayPills` are view-space
    /// rounded rects painted above everything.
    public func encode(
        layout: DocumentLayout,
        theme: Theme,
        originPts: CGPoint,
        scale: CGFloat,
        selectionRects: [CGRect] = [],
        overlayPills: [OverlayPill] = [],
        target: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        scaleChanged(scale)

        // Rounded ONCE per frame — per-quad rounding of a shared offset is how
        // scroll shimmer happens.
        let originDev = SIMD2<Float>(
            Float((originPts.x * scale).rounded()),
            Float((originPts.y * scale).rounded())
        )
        let viewportHeightDev = Float(target.height)

        var solidsBelow: [SolidQuad] = []
        var solidsAbove: [SolidQuad] = []
        var grayGlyphs: [Int: [GlyphQuad]] = [:]
        var colorGlyphs: [Int: [GlyphQuad]] = [:]

        let pageBackground = theme.color(.pageBackground)
        let pageLuminance = (pageBackground.x + pageBackground.y + pageBackground.z) / 3

        for block in layout.blocks {
            let blockTopDev = originDev.y + Float((block.yPts * scale).rounded())
            let blockHeightDev = Float((block.heightPts * scale).rounded())
            // Viewport cull. P3 replaces the linear walk with the geometry tree.
            if blockTopDev > viewportHeightDev || blockTopDev + blockHeightDev < 0 {
                continue
            }

            for background in block.backgrounds {
                solidsBelow.append(SolidQuad(
                    origin: SIMD2(
                        originDev.x + Float((background.rectPts.minX * scale).rounded()),
                        blockTopDev + Float((background.rectPts.minY * scale).rounded())
                    ),
                    size: SIMD2(
                        Float((background.rectPts.width * scale).rounded()),
                        max(1, Float((background.rectPts.height * scale).rounded()))
                    ),
                    color: theme.color(background.color)
                ))
            }

            // Local backdrop decides mask polarity (code blocks sit on their own
            // background).
            let localBackground = block.kind == .codeBlock ? theme.color(.codeBackground) : pageBackground
            let localLuminance = block.kind == .codeBlock
                ? (localBackground.x + localBackground.y + localBackground.z) / 3
                : pageLuminance

            let textOrigin = SIMD2<Float>(
                originDev.x + Float((block.textInsetPts.x * scale).rounded()),
                blockTopDev + Float((block.textInsetPts.y * scale).rounded())
            )

            // List marker: right-aligned into the indent column, 8pt gap,
            // sharing the first line's baseline.
            if let markerRuns = block.shaped.marker {
                let markerOrigin = SIMD2<Float>(
                    textOrigin.x - Float(((block.shaped.markerWidthPts + 8) * scale).rounded()),
                    textOrigin.y
                )
                for run in markerRuns {
                    appendRun(
                        run, textOrigin: markerOrigin,
                        theme: theme, backdropLuminance: localLuminance,
                        gray: &grayGlyphs, color: &colorGlyphs
                    )
                }
            }

            for placed in block.shaped.positionedLines {
                // Flow top rounds once (whole pixels); the line's baselineDev
                // already encodes its stacking within the flow. x offsets stay
                // fractional — subpixel buckets absorb them.
                let lineOrigin = SIMD2<Float>(
                    textOrigin.x + Float(placed.xOffsetPts * scale),
                    textOrigin.y + Float((placed.flowTopPts * scale).rounded())
                )
                let baselineDev = lineOrigin.y + Float(placed.line.baselineDev)
                if baselineDev < -64 || baselineDev > viewportHeightDev + 64 { continue }

                for run in placed.line.runs {
                    appendRun(
                        run, textOrigin: lineOrigin,
                        theme: theme, backdropLuminance: localLuminance,
                        gray: &grayGlyphs, color: &colorGlyphs
                    )
                }
                for decoration in placed.line.decorations {
                    solidsAbove.append(SolidQuad(
                        origin: SIMD2(
                            lineOrigin.x + Float((decoration.rectPts.minX * scale).rounded()),
                            lineOrigin.y + Float((decoration.rectPts.minY * scale).rounded())
                        ),
                        size: SIMD2(
                            Float((decoration.rectPts.width * scale).rounded()),
                            max(1, Float((decoration.rectPts.height * scale).rounded()))
                        ),
                        color: theme.color(decoration.color)
                    ))
                }
            }
        }

        // Selection paints over block backgrounds, under glyphs — appended
        // after backgrounds so instance order gives the painter's order.
        if !selectionRects.isEmpty {
            let selectionColor = theme.color(.selection)
            for rect in selectionRects {
                let top = originDev.y + Float((rect.minY * scale).rounded())
                let height = Float((rect.height * scale).rounded())
                guard top <= viewportHeightDev, top + height >= 0 else { continue }
                solidsBelow.append(SolidQuad(
                    origin: SIMD2(originDev.x + Float((rect.minX * scale).rounded()), top),
                    size: SIMD2(Float((rect.width * scale).rounded()), height),
                    color: selectionColor
                ))
            }
        }

        let clear = theme.color(.pageBackground)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: 1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var viewport = SIMD2<Float>(Float(target.width), Float(target.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        drawSolids(solidsBelow, encoder: encoder)
        encoder.setRenderPipelineState(grayPipeline)
        for (pageIndex, quads) in grayGlyphs.sorted(by: { $0.key < $1.key }) {
            drawGlyphs(quads, texture: atlas.grayPages[pageIndex].texture, encoder: encoder)
        }
        encoder.setRenderPipelineState(colorPipeline)
        for (pageIndex, quads) in colorGlyphs.sorted(by: { $0.key < $1.key }) {
            drawGlyphs(quads, texture: atlas.colorPages[pageIndex].texture, encoder: encoder)
        }
        drawSolids(solidsAbove, encoder: encoder)
        if !overlayPills.isEmpty {
            let pills = overlayPills.map { pill in
                PillQuad(
                    origin: SIMD2(Float(pill.rectPts.minX * scale), Float(pill.rectPts.minY * scale)),
                    size: SIMD2(Float(pill.rectPts.width * scale), Float(pill.rectPts.height * scale)),
                    color: pill.color,
                    radius: Float(pill.cornerRadiusPts * scale)
                )
            }
            drawPills(pills, encoder: encoder)
        }
        encoder.endEncoding()
    }

    private func drawPills(_ pills: [PillQuad], encoder: MTLRenderCommandEncoder) {
        guard !pills.isEmpty,
              let buffer = device.makeBuffer(
                  bytes: pills,
                  length: pills.count * MemoryLayout<PillQuad>.stride,
                  options: .storageModeShared
              )
        else { return }
        encoder.setRenderPipelineState(pillPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pills.count)
    }

    private func appendRun(
        _ run: ShapedGlyphRun,
        textOrigin: SIMD2<Float>,
        theme: Theme,
        backdropLuminance: Float,
        gray: inout [Int: [GlyphQuad]],
        color: inout [Int: [GlyphQuad]]
    ) {
        let fontIndex = atlas.fontIndex(for: run.font)
        let runColor = theme.color(run.color)
        let darkOnLight = (runColor.x + runColor.y + runColor.z) / 3 < backdropLuminance
        let pageSize = Float(GlyphAtlas.pageSize)

        for i in run.glyphs.indices {
            let xExact = CGFloat(textOrigin.x) + run.positionsDev[i].x
            // positionsDev.y already carries the block-relative whole-pixel
            // baseline (plus any run offset); text origin is integral too.
            let yDev = (textOrigin.y + Float(run.positionsDev[i].y)).rounded()

            var xInt = xExact.rounded(.down)
            var bucket = 0
            if run.isColorGlyphs {
                xInt = xExact.rounded()
            } else {
                bucket = Int(((xExact - xInt) * CGFloat(GlyphAtlas.subpixelBuckets)).rounded())
                if bucket == GlyphAtlas.subpixelBuckets {
                    bucket = 0
                    xInt += 1
                }
            }

            guard let entry = atlas.entry(
                fontIndex: fontIndex, glyph: run.glyphs[i], bucket: bucket,
                isColor: run.isColorGlyphs, darkOnLight: darkOnLight
            ) else { continue }

            let quad = GlyphQuad(
                origin: SIMD2(Float(xInt) + Float(entry.bearingX), yDev - Float(entry.bearingTop)),
                size: SIMD2(Float(entry.width), Float(entry.height)),
                uvOrigin: SIMD2(Float(entry.x) / pageSize, Float(entry.y) / pageSize),
                uvSize: SIMD2(Float(entry.width) / pageSize, Float(entry.height) / pageSize),
                color: runColor
            )
            if run.isColorGlyphs {
                color[entry.pageIndex, default: []].append(quad)
            } else {
                gray[entry.pageIndex, default: []].append(quad)
            }
        }
    }

    private func drawSolids(_ solids: [SolidQuad], encoder: MTLRenderCommandEncoder) {
        guard !solids.isEmpty,
              let buffer = device.makeBuffer(
                  bytes: solids,
                  length: solids.count * MemoryLayout<SolidQuad>.stride,
                  options: .storageModeShared
              )
        else { return }
        encoder.setRenderPipelineState(solidPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: solids.count)
    }

    private func drawGlyphs(_ quads: [GlyphQuad], texture: MTLTexture, encoder: MTLRenderCommandEncoder) {
        guard !quads.isEmpty,
              let buffer = device.makeBuffer(
                  bytes: quads,
                  length: quads.count * MemoryLayout<GlyphQuad>.stride,
                  options: .storageModeShared
              )
        else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
    }

    // MARK: - Convenience

    /// Synchronous offscreen render — snapshot tests and frame dumps.
    public func renderOffscreen(
        layout: DocumentLayout, theme: Theme, originPts: CGPoint,
        scale: CGFloat, selectionRects: [CGRect] = [], overlayPills: [OverlayPill] = [],
        width: Int, height: Int
    ) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let commandBuffer = commandQueue.makeCommandBuffer()!
        encode(
            layout: layout, theme: theme, originPts: originPts, scale: scale,
            selectionRects: selectionRects, overlayPills: overlayPills,
            target: texture, commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    /// Encode + present into a drawable-backed texture using a caller-provided
    /// command buffer (the viewer owns present timing).
    public func makeCommandBuffer() -> MTLCommandBuffer? {
        commandQueue.makeCommandBuffer()
    }

    /// BGRA8 readback (byteOrder32Little + premultipliedFirst).
    public static func bgraBytes(from texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
            )
        }
        return bytes
    }
}
