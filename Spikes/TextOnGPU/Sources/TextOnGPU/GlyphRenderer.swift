import CoreGraphics
import Metal
import QuartzCore

// Instanced-quad text renderer: one draw call per atlas page in use. For this
// spike's sample that's typically 2 draws (one gray page, one color page).

@MainActor
final class GlyphRenderer {
    /// Layout must match GlyphInstance in the MSL source: 3 float2 pairs then a
    /// 16-aligned float4 → stride 48.
    struct Instance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        var color: SIMD4<Float>
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let grayPipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState

    init(device: MTLDevice) throws {
        precondition(MemoryLayout<Instance>.stride == 48, "Instance layout diverged from MSL")
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        let library = try device.makeLibrary(source: glyphShaderSource, options: nil)
        grayPipeline = try Self.makePipeline(device: device, library: library, fragment: "glyph_fragment_gray")
        colorPipeline = try Self.makePipeline(device: device, library: library, fragment: "glyph_fragment_color")
    }

    private static func makePipeline(
        device: MTLDevice, library: MTLLibrary, fragment: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "glyph_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        // Premultiplied source-over.
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Frame encoding

    /// Draw `shaped` into `target`, offset by `offset` device pixels (the
    /// animated-subpixel test drives this with fractional values).
    func encode(
        shaped: ShapedText,
        atlas: GlyphAtlas,
        offset: CGPoint,
        background: CGColor,
        target: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        var grayInstances: [Int: [Instance]] = [:]
        var colorInstances: [Int: [Instance]] = [:]
        let bg = sRGBComponents(background)
        let backgroundLuminance = (bg.x + bg.y + bg.z) / 3

        for line in shaped.lines {
            for run in line.runs {
                let fontIndex = atlas.fontIndex(for: run.font)
                let color = sRGBComponents(run.color)
                let darkOnLight = (color.x + color.y + color.z) / 3 < backgroundLuminance
                for i in run.glyphs.indices {
                    let xExact = run.positions[i].x + offset.x
                    let yInt = Float((run.positions[i].y + offset.y).rounded())

                    var xInt = xExact.rounded(.down)
                    var bucket = 0
                    if run.isColor {
                        // Emoji are big; whole-pixel placement, single bucket.
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
                        isColor: run.isColor, darkOnLight: darkOnLight
                    ) else { continue }

                    let pageSize = Float(GlyphAtlas.pageSize)
                    let instance = Instance(
                        origin: SIMD2(Float(xInt) + Float(entry.bearingX), yInt - Float(entry.bearingTop)),
                        size: SIMD2(Float(entry.width), Float(entry.height)),
                        uvOrigin: SIMD2(Float(entry.x) / pageSize, Float(entry.y) / pageSize),
                        uvSize: SIMD2(Float(entry.width) / pageSize, Float(entry.height) / pageSize),
                        color: color
                    )
                    if run.isColor {
                        colorInstances[entry.pageIndex, default: []].append(instance)
                    } else {
                        grayInstances[entry.pageIndex, default: []].append(instance)
                    }
                }
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor(background)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var viewport = SIMD2<Float>(Float(target.width), Float(target.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        encoder.setRenderPipelineState(grayPipeline)
        for (pageIndex, instances) in grayInstances.sorted(by: { $0.key < $1.key }) {
            drawInstances(instances, texture: atlas.grayPages[pageIndex].texture, encoder: encoder)
        }
        encoder.setRenderPipelineState(colorPipeline)
        for (pageIndex, instances) in colorInstances.sorted(by: { $0.key < $1.key }) {
            drawInstances(instances, texture: atlas.colorPages[pageIndex].texture, encoder: encoder)
        }
        encoder.endEncoding()
    }

    private func drawInstances(_ instances: [Instance], texture: MTLTexture, encoder: MTLRenderCommandEncoder) {
        guard !instances.isEmpty,
              let buffer = device.makeBuffer(
                  bytes: instances,
                  length: instances.count * MemoryLayout<Instance>.stride,
                  options: .storageModeShared
              )
        else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count
        )
    }

    // MARK: - Convenience entry points

    /// Offscreen render, synchronous. Used by dump mode and (later) snapshots.
    func renderOffscreen(
        shaped: ShapedText, atlas: GlyphAtlas, offset: CGPoint = .zero,
        background: CGColor, width: Int, height: Int
    ) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let commandBuffer = commandQueue.makeCommandBuffer()!
        encode(
            shaped: shaped, atlas: atlas, offset: offset,
            background: background, target: texture, commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    /// On-screen render into the layer's next drawable.
    func render(
        to layer: CAMetalLayer, shaped: ShapedText, atlas: GlyphAtlas,
        offset: CGPoint, background: CGColor
    ) {
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        encode(
            shaped: shaped, atlas: atlas, offset: offset,
            background: background, target: drawable.texture, commandBuffer: commandBuffer
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

func sRGBComponents(_ color: CGColor) -> SIMD4<Float> {
    let srgb = color.converted(
        to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
    ) ?? color
    let c = srgb.components ?? [0, 0, 0, 1]
    if c.count >= 4 {
        return SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
    }
    return SIMD4(Float(c[0]), Float(c[0]), Float(c[0]), c.count > 1 ? Float(c[1]) : 1)
}

func clearColor(_ color: CGColor) -> MTLClearColor {
    let c = sRGBComponents(color)
    // Encoded values pass straight into the non-sRGB attachment — same gamma
    // convention as the glyph blending.
    return MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: Double(c.w))
}
