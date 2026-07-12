import AppKit
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers
import VWLayout
import VWRender
import VWStyle

/// The document surface: NSView backed by a CAMetalLayer (not MTKView — we own
/// drawable timing and presentsWithTransaction).
///
/// First-frame contract: `prepareFirstFrame` runs the whole pipeline and
/// presents WITH the current CATransaction, so the window's first on-screen
/// commit already contains rendered markdown. The caller orders the window
/// front afterwards; `presented` fires with the honest glass timestamp from
/// MTLDrawable.addPresentedHandler.
@MainActor
public final class DocumentEngineView: NSView {
    private static let maxContentWidthPts: CGFloat = 720
    private static let horizontalInsetPts: CGFloat = 28
    private static let verticalInsetPts: CGFloat = 28

    private let session: DocumentSession
    private var renderer: DocumentRenderer?
    private var scrollOffsetPts: CGFloat = 0
    private var firstFramePresented = false

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public init(data: Data, theme: Theme) {
        self.session = DocumentSession(data: data, theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("vw builds UI in code; no archives")
    }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        return layer
    }

    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Geometry

    private var scale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private var contentWidthPts: CGFloat {
        min(Self.maxContentWidthPts, max(120, bounds.width - Self.horizontalInsetPts * 2))
    }

    private var contentOriginPts: CGPoint {
        CGPoint(
            x: max(Self.horizontalInsetPts, (bounds.width - contentWidthPts) / 2),
            y: Self.verticalInsetPts - scrollOffsetPts
        )
    }

    private var maxScrollPts: CGFloat {
        guard let layout = session.layout else { return 0 }
        return max(0, layout.contentHeightPts + Self.verticalInsetPts * 2 - bounds.height)
    }

    // MARK: - First frame

    /// Parse → flatten → layout → encode → present, all before the window is
    /// visible. `presented` may be called on an arbitrary queue.
    public func prepareFirstFrame(
        mark: @escaping (String) -> Void,
        presented: @escaping @Sendable (CFTimeInterval) -> Void
    ) {
        let scale = scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        session.prepare(contentWidth: contentWidthPts, scale: scale, mark: mark)

        guard let renderer = ensureRenderer(), let layout = session.layout else {
            presented(CACurrentMediaTime())
            return
        }

        metalLayer.presentsWithTransaction = true
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = renderer.makeCommandBuffer()
        else {
            // No drawable pre-visibility (headless edge): fall back to a normal
            // render on the next runloop turn; time via transaction completion.
            CATransaction.begin()
            CATransaction.setCompletionBlock { presented(CACurrentMediaTime()) }
            needsDisplay = true
            CATransaction.commit()
            return
        }

        renderer.encode(
            layout: layout, theme: session.theme, originPts: contentOriginPts,
            scale: scale, target: drawable.texture, commandBuffer: commandBuffer
        )
        mark("encode")
        drawable.addPresentedHandler { presentedDrawable in
            // presentedTime is 0 when CA never displayed the drawable; fall
            // back to "now" rather than poisoning the trace.
            let glassTime = presentedDrawable.presentedTime
            presented(glassTime > 0 ? glassTime : CACurrentMediaTime())
        }
        commandBuffer.commit()
        // presentsWithTransaction: schedule, then present inside the current
        // transaction so the first window commit carries this frame. The flag
        // stays on until the next steady-state render — flipping it before the
        // transaction commits re-routes the pending presentation.
        commandBuffer.waitUntilScheduled()
        drawable.present()
        firstFramePresented = true

        dumpFrameIfRequested(renderer: renderer, layout: layout, scale: scale)
    }

    private func ensureRenderer() -> DocumentRenderer? {
        if let renderer { return renderer }
        renderer = try? DocumentRenderer(scale: scale)
        return renderer
    }

    // MARK: - Steady-state rendering

    private func render() {
        guard let renderer = ensureRenderer(), let layout = session.layout,
              bounds.width > 0, bounds.height > 0
        else { return }
        if metalLayer.presentsWithTransaction {
            // First-frame mode ends at the first steady-state render.
            metalLayer.presentsWithTransaction = false
        }
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = renderer.makeCommandBuffer()
        else { return }
        renderer.encode(
            layout: layout, theme: session.theme, originPts: contentOriginPts,
            scale: scale, target: drawable.texture, commandBuffer: commandBuffer
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func reshapeAndRender() {
        guard window != nil, firstFramePresented else { return }
        let scale = scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        renderer?.scaleChanged(scale)
        session.prepare(contentWidth: contentWidthPts, scale: scale)
        scrollOffsetPts = min(scrollOffsetPts, maxScrollPts)
        render()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reshapeAndRender()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reshapeAndRender()
    }

    // MARK: - Scrolling (minimal; momentum/rubber-band/display-link land in P3)

    public override func scrollWheel(with event: NSEvent) {
        guard session.layout != nil else { return }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 3 * session.theme.metrics.bodySize
        let clamped = min(max(0, scrollOffsetPts - delta), maxScrollPts)
        guard clamped != scrollOffsetPts else { return }
        scrollOffsetPts = clamped
        render()
    }

    // MARK: - Frame dump (VW_DUMP_FRAME=/path.png — autonomous visual checks)

    private func dumpFrameIfRequested(renderer: DocumentRenderer, layout: DocumentLayout, scale: CGFloat) {
        guard let path = ProcessInfo.processInfo.environment["VW_DUMP_FRAME"], !path.isEmpty else { return }
        let texture = renderer.renderOffscreen(
            layout: layout, theme: session.theme, originPts: contentOriginPts, scale: scale,
            width: Int(bounds.width * scale), height: Int(bounds.height * scale)
        )
        let bytes = DocumentRenderer.bgraBytes(from: texture)
        writeBGRAPNG(bytes, width: texture.width, height: texture.height, to: URL(fileURLWithPath: path))
    }
}

func writeBGRAPNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) {
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
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.png.identifier as CFString, 1, nil
          )
    else { return }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
}
