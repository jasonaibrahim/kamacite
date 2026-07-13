import Metal

/// Process-wide GPU state: device, compiled shader library, pipelines. Shader
/// compilation costs ~100ms and must never sit on the open path — warmUp()
/// kicks it on a background queue at process start (MTLCompilerService runs
/// out-of-process, genuinely parallel with AppKit spin-up), and pipelines()
/// blocks only for whatever hasn't finished by first-frame time.
///
/// All Metal objects vended here are immutable and thread-safe.
public final class RendererCore: @unchecked Sendable {
    public struct Pipelines: @unchecked Sendable {
        public let device: MTLDevice
        let solid: MTLRenderPipelineState
        let gray: MTLRenderPipelineState
        let color: MTLRenderPipelineState
        let pill: MTLRenderPipelineState
    }

    public static let shared = RendererCore()

    private let lock = NSLock()
    private let group = DispatchGroup()
    private var started = false
    private var result: Result<Pipelines, Error>?

    /// Idempotent; safe from any thread. Call as early in the process as possible.
    public func warmUp() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try Self.build() }
            self.lock.lock()
            self.result = outcome
            self.lock.unlock()
            self.group.leave()
        }
    }

    /// Blocks until the warm-up finishes (no-op when it already has).
    public func pipelines() throws -> Pipelines {
        warmUp()
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }

    private static func build() throws -> Pipelines {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noDevice
        }
        let library = try device.makeLibrary(source: documentShaderSource, options: nil)

        func pipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
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

        return Pipelines(
            device: device,
            solid: try pipeline(vertex: "solid_vertex", fragment: "solid_fragment"),
            gray: try pipeline(vertex: "glyph_vertex", fragment: "glyph_fragment_gray"),
            color: try pipeline(vertex: "glyph_vertex", fragment: "glyph_fragment_color"),
            pill: try pipeline(vertex: "pill_vertex", fragment: "pill_fragment")
        )
    }
}

public enum RendererError: Error {
    case noDevice
}
