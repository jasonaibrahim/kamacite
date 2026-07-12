import AppKit
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers
import VWCore
import VWInteraction
import VWLayout
import VWRender
import VWStyle

/// The document surface: NSView backed by a CAMetalLayer (not MTKView — we own
/// drawable timing and presentsWithTransaction).
///
/// Render loop: events mark the frame dirty and the CADisplayLink draws once
/// per refresh while there's work (scroll, snap-back, autoscroll, selection),
/// then pauses. Layout is viewport-lazy: each frame prepares only the blocks
/// near the viewport and scroll-anchors any estimate corrections above it.
@MainActor
public final class DocumentEngineView: NSView {
    private static let maxContentWidthPts: CGFloat = 720
    private static let horizontalInsetPts: CGFloat = 28
    private static let verticalInsetPts: CGFloat = 28
    private static let rubberBandStiffness: CGFloat = 130
    private static let snapBackDuration: CFTimeInterval = 0.30

    private let session: DocumentSession
    private var renderer: DocumentRenderer?
    private var firstFramePresented = false

    // Scroll state. scrollOffsetPts may leave [0, maxScroll] while rubber-banding.
    private var scrollOffsetPts: CGFloat = 0
    private var gestureActive = false
    private var momentumActive = false
    private var snapBack: (from: CGFloat, to: CGFloat, startedAt: CFTimeInterval)?

    // Render loop.
    private var displayLink: CADisplayLink?
    private var frameDirty = false
    private var idleTicks = 0

    // Selection.
    private var selection: DocumentSelection?
    private var dragging = false
    private var lastDragViewPoint: CGPoint = .zero
    private var autoscrollVelocityPts: CGFloat = 0

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
    /// Top-left origin: mouse math and document space agree.
    public override var isFlipped: Bool { true }

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

    /// Document-space y range currently on glass.
    private var visibleDocRange: Range<CGFloat> {
        let top = scrollOffsetPts - Self.verticalInsetPts
        return top..<(top + max(bounds.height, 1))
    }

    private func docPoint(fromViewPoint p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - contentOriginPts.x, y: p.y - contentOriginPts.y)
    }

    // MARK: - First frame

    /// Parse → flatten → estimate → shape viewport → encode → present, all
    /// before the window is visible. `presented` may be called on any queue.
    public func prepareFirstFrame(
        mark: @escaping (String) -> Void,
        presented: @escaping @Sendable (CFTimeInterval) -> Void
    ) {
        let scale = scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        session.prepare(contentWidth: contentWidthPts, scale: scale, mark: mark)
        if let layout = session.layout {
            layout.prepare(docRange: expand(visibleDocRange, by: bounds.height), anchorY: 0)
            mark("shape")
        }

        guard let renderer = ensureRenderer(), session.layout != nil else {
            presented(CACurrentMediaTime())
            return
        }

        metalLayer.presentsWithTransaction = true
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = renderer.makeCommandBuffer()
        else {
            CATransaction.begin()
            CATransaction.setCompletionBlock { presented(CACurrentMediaTime()) }
            needsDisplay = true
            CATransaction.commit()
            return
        }

        let frame = buildFrame()
        renderer.encode(
            layout: frame.layout, theme: session.theme, originPts: contentOriginPts,
            scale: scale, selectionRects: frame.selectionRects,
            target: drawable.texture, commandBuffer: commandBuffer
        )
        mark("encode")
        drawable.addPresentedHandler { presentedDrawable in
            let glassTime = presentedDrawable.presentedTime
            presented(glassTime > 0 ? glassTime : CACurrentMediaTime())
        }
        commandBuffer.commit()
        // presentsWithTransaction: schedule, then present inside the current
        // transaction so the first window commit carries this frame. The flag
        // stays on until the next steady-state render.
        commandBuffer.waitUntilScheduled()
        drawable.present()
        firstFramePresented = true

        dumpFrameIfRequested(renderer: renderer, frame: frame, scale: scale)
        scheduleScrollBenchIfRequested()
    }

    private func ensureRenderer() -> DocumentRenderer? {
        if let renderer { return renderer }
        renderer = try? DocumentRenderer(scale: scale)
        return renderer
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayTick))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    // MARK: - Frame building (lazy layout + anchoring + selection)

    private struct Frame {
        let layout: DocumentLayout
        let selectionRects: [CGRect]
    }

    private func buildFrame() -> Frame {
        guard let layout = session.layout else {
            return Frame(
                layout: DocumentLayout(blocks: [], contentWidthPts: contentWidthPts, contentHeightPts: 0),
                selectionRects: []
            )
        }

        // Shape one screen beyond each edge; anchor corrections at the top of
        // the viewport so exact heights never move what's on glass.
        let anchorY = max(0, visibleDocRange.lowerBound)
        let adjustment = layout.prepare(
            docRange: expand(visibleDocRange, by: bounds.height), anchorY: anchorY
        )
        if adjustment != 0 {
            scrollOffsetPts += adjustment
        }

        let visible = visibleDocRange
        let blocks = layout.placedBlocks(in: visible)

        var rects: [CGRect] = []
        if let selection, !selection.isEmpty {
            for block in blocks {
                rects.append(contentsOf: selectionRects(selection: selection, block: block))
            }
        }

        layout.evict(keeping: expand(visible, by: bounds.height * 4))

        return Frame(
            layout: DocumentLayout(
                blocks: blocks,
                contentWidthPts: layout.contentWidth,
                contentHeightPts: layout.contentHeightPts
            ),
            selectionRects: rects
        )
    }

    private func expand(_ range: Range<CGFloat>, by margin: CGFloat) -> Range<CGFloat> {
        (range.lowerBound - margin)..<(range.upperBound + margin)
    }

    // MARK: - Steady-state rendering

    private func setNeedsRender() {
        frameDirty = true
        idleTicks = 0
        displayLink?.isPaused = false
    }

    @objc private func displayTick() {
        var animating = false

        if let snapBack {
            let t = min(1, (CACurrentMediaTime() - snapBack.startedAt) / Self.snapBackDuration)
            let eased = 1 - pow(1 - t, 3)
            scrollOffsetPts = snapBack.from + (snapBack.to - snapBack.from) * eased
            if t >= 1 {
                scrollOffsetPts = snapBack.to
                self.snapBack = nil
            } else {
                animating = true
            }
            frameDirty = true
        }

        if dragging, autoscrollVelocityPts != 0 {
            scrollOffsetPts = min(max(0, scrollOffsetPts + autoscrollVelocityPts), maxScrollPts)
            extendSelection(toViewPoint: lastDragViewPoint)
            animating = true
            frameDirty = true
        }

        if frameDirty {
            frameDirty = false
            render()
        }

        if animating {
            idleTicks = 0
        } else {
            idleTicks += 1
            if idleTicks > 30 {
                displayLink?.isPaused = true
            }
        }
    }

    private func render() {
        guard let renderer = ensureRenderer(), session.layout != nil,
              bounds.width > 0, bounds.height > 0
        else { return }
        if metalLayer.presentsWithTransaction {
            metalLayer.presentsWithTransaction = false
        }
        let frame = buildFrame()
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = renderer.makeCommandBuffer()
        else { return }
        renderer.encode(
            layout: frame.layout, theme: session.theme, originPts: contentOriginPts,
            scale: scale, selectionRects: frame.selectionRects,
            target: drawable.texture, commandBuffer: commandBuffer
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func reshapeAndRender() {
        guard window != nil, firstFramePresented, let layout = session.layout else { return }
        let scale = scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        renderer?.scaleChanged(scale)

        // Anchor the top visible block across the reflow.
        let docTop = max(0, visibleDocRange.lowerBound)
        let anchorIndex = layout.blockIndex(at: docTop)
        let withinBlock = docTop - layout.yOffset(of: anchorIndex)

        session.prepare(contentWidth: contentWidthPts, scale: scale)
        layout.prepare(docRange: expand(visibleDocRange, by: bounds.height), anchorY: docTop)
        let newTop = layout.yOffset(of: anchorIndex) + max(0, withinBlock)
        scrollOffsetPts = min(max(0, newTop + Self.verticalInsetPts), maxScrollPts)
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

    // MARK: - Appearance (mandatory: live re-render, no re-layout)

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let newTheme: Theme = isDark ? .dark : .light
        guard newTheme.name != session.theme.name else { return }
        session.setTheme(newTheme)
        setNeedsRender()
    }

    // MARK: - Scrolling

    public override func scrollWheel(with event: NSEvent) {
        guard session.layout != nil else { return }

        switch event.phase {
        case .began:
            gestureActive = true
            snapBack = nil
        case .ended, .cancelled:
            gestureActive = false
        default:
            break
        }
        switch event.momentumPhase {
        case .began:
            momentumActive = true
            snapBack = nil
        case .ended, .cancelled:
            momentumActive = false
        default:
            break
        }

        let hasPhases = event.phase != [] || event.momentumPhase != []
        var delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 3 * session.theme.metrics.bodySize

        if hasPhases, maxScrollPts > 0 {
            let overshoot = currentOvershoot()
            if overshoot != 0 {
                // Rubber-band resistance grows with displacement; momentum
                // gets eaten almost entirely.
                let resistance = momentumActive
                    ? 0.05
                    : 1 / (1 + abs(overshoot) / Self.rubberBandStiffness)
                delta *= resistance
            }
            scrollOffsetPts -= delta

            let stillGesturing = gestureActive || momentumActive
            if !stillGesturing, currentOvershoot() != 0 {
                beginSnapBack()
            }
            if momentumActive, abs(currentOvershoot()) > 90 {
                // Deep overscroll on momentum: stop absorbing, snap home.
                momentumActive = false
                beginSnapBack()
            }
        } else {
            // Legacy mice: plain clamped scrolling.
            scrollOffsetPts = min(max(0, scrollOffsetPts - delta), maxScrollPts)
        }

        setNeedsRender()
    }

    private func currentOvershoot() -> CGFloat {
        if scrollOffsetPts < 0 { return scrollOffsetPts }
        if scrollOffsetPts > maxScrollPts { return scrollOffsetPts - maxScrollPts }
        return 0
    }

    private func beginSnapBack() {
        let target = min(max(0, scrollOffsetPts), maxScrollPts)
        guard target != scrollOffsetPts else { return }
        snapBack = (from: scrollOffsetPts, to: target, startedAt: CACurrentMediaTime())
        setNeedsRender()
    }

    // MARK: - Selection (mandatory)

    public override func mouseDown(with event: NSEvent) {
        guard session.layout != nil else { return }
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let position = textPosition(atViewPoint: viewPoint)

        switch event.clickCount {
        case 2:
            selection = expandToWord(at: position)
        case 3:
            selection = expandToBlock(at: position)
        default:
            selection = DocumentSelection(caret: position)
            dragging = true
            lastDragViewPoint = viewPoint
        }
        setNeedsRender()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        lastDragViewPoint = viewPoint

        // Drag past an edge autoscrolls proportionally, driven by the display link.
        if viewPoint.y < 0 {
            autoscrollVelocityPts = max(viewPoint.y * 0.25, -40)
        } else if viewPoint.y > bounds.height {
            autoscrollVelocityPts = min((viewPoint.y - bounds.height) * 0.25, 40)
        } else {
            autoscrollVelocityPts = 0
        }

        extendSelection(toViewPoint: viewPoint)
        setNeedsRender()
    }

    public override func mouseUp(with event: NSEvent) {
        dragging = false
        autoscrollVelocityPts = 0
    }

    private func extendSelection(toViewPoint viewPoint: CGPoint) {
        guard var current = selection else { return }
        current.focus = textPosition(atViewPoint: viewPoint)
        selection = current
        frameDirty = true
    }

    private func textPosition(atViewPoint viewPoint: CGPoint) -> TextPosition {
        guard let layout = session.layout, layout.blockCount > 0 else {
            return TextPosition(blockIndex: 0, utf16Offset: 0)
        }
        let doc = docPoint(fromViewPoint: viewPoint)
        let index = layout.blockIndex(at: doc.y)
        let block = layout.placedBlock(at: index)
        return VWInteraction.textPosition(at: doc, in: block)
    }

    private func expandToWord(at position: TextPosition) -> DocumentSelection {
        guard let layout = session.layout else { return DocumentSelection(caret: position) }
        let block = layout.placedBlock(at: position.blockIndex)
        let range = wordRange(in: block.shaped.text, aroundUTF16: position.utf16Offset)
        return DocumentSelection(
            anchor: TextPosition(blockIndex: position.blockIndex, utf16Offset: range.location),
            focus: TextPosition(blockIndex: position.blockIndex, utf16Offset: range.location + range.length)
        )
    }

    private func expandToBlock(at position: TextPosition) -> DocumentSelection {
        guard let layout = session.layout else { return DocumentSelection(caret: position) }
        let block = layout.placedBlock(at: position.blockIndex)
        return DocumentSelection(
            anchor: TextPosition(blockIndex: position.blockIndex, utf16Offset: 0),
            focus: TextPosition(blockIndex: position.blockIndex, utf16Offset: block.shaped.utf16Length)
        )
    }

    public override func selectAll(_ sender: Any?) {
        guard let document = session.document, !document.blocks.isEmpty else { return }
        let lastLength = (document.blocks[document.blocks.count - 1].runs.map(\.text).joined() as NSString).length
        selection = DocumentSelection(
            anchor: TextPosition(blockIndex: 0, utf16Offset: 0),
            focus: TextPosition(blockIndex: document.blocks.count - 1, utf16Offset: lastLength)
        )
        setNeedsRender()
    }

    @objc public func copy(_ sender: Any?) {
        guard let selection, !selection.isEmpty, let document = session.document else { return }
        let text = selectedPlainText(selection: selection, document: document)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘⇧C — the byte-exact markdown source slice, via SourceSpans.
    @objc public func copyMarkdownSource(_ sender: Any?) {
        guard let selection, !selection.isEmpty, let document = session.document,
              let span = selectedSourceByteRange(selection: selection, document: document)
        else { return }
        let start = min(span.startUTF8, session.data.count)
        let end = min(span.endUTF8, session.data.count)
        guard end > start else { return }
        let text = String(decoding: session.data[start..<end], as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: - Debug hooks

    private func dumpFrameIfRequested(renderer: DocumentRenderer, frame: Frame, scale: CGFloat) {
        guard let path = ProcessInfo.processInfo.environment["VW_DUMP_FRAME"], !path.isEmpty else { return }
        let texture = renderer.renderOffscreen(
            layout: frame.layout, theme: session.theme, originPts: contentOriginPts, scale: scale,
            width: Int(bounds.width * scale), height: Int(bounds.height * scale)
        )
        let bytes = DocumentRenderer.bgraBytes(from: texture)
        writeBGRAPNG(bytes, width: texture.width, height: texture.height, to: URL(fileURLWithPath: path))
    }

    /// VW_SCROLL_BENCH=1: after first present, time N synthetic scroll frames
    /// (each fully serialized encode→GPU-complete — a pessimistic upper bound),
    /// print stats, exit. Runs the REAL frame path: lazy prepare, anchoring,
    /// selection plumbing, eviction.
    private func scheduleScrollBenchIfRequested() {
        guard ProcessInfo.processInfo.environment["VW_SCROLL_BENCH"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.runScrollBench()
        }
    }

    private func runScrollBench() {
        guard let renderer = ensureRenderer(), session.layout != nil else { exit(1) }
        let frames = 480
        let step: CGFloat = 9 // ~1080 pts/s at 120Hz — fast reading scroll
        var times: [Double] = []
        times.reserveCapacity(frames)

        for i in 0..<frames {
            scrollOffsetPts = min(max(0, scrollOffsetPts + (i < frames / 2 ? step : -step)), maxScrollPts)
            let start = CACurrentMediaTime()
            let frame = buildFrame()
            let texture = renderer.renderOffscreen(
                layout: frame.layout, theme: session.theme, originPts: contentOriginPts,
                scale: scale, width: Int(bounds.width * scale), height: Int(bounds.height * scale)
            )
            _ = texture
            times.append((CACurrentMediaTime() - start) * 1000)
        }

        times.sort()
        let p50 = times[times.count / 2]
        let p95 = times[Int(Double(times.count) * 0.95)]
        let p99 = times[Int(Double(times.count) * 0.99)]
        let worst = times.last ?? 0
        let shaped = session.layout?.shapedBlockCount ?? 0
        FileHandle.standardError.write(Data("""
        vw scroll-bench  \(frames) frames, serialized encode+GPU
          p50 \(String(format: "%.2f", p50)) ms   p95 \(String(format: "%.2f", p95)) ms   p99 \(String(format: "%.2f", p99)) ms   worst \(String(format: "%.2f", worst)) ms
          budget 8.33 ms/frame @120Hz — \(p95 <= 8.33 ? "PASS" : "FAIL") (p95)
          shaped blocks resident: \(shaped) of \(session.layout?.blockCount ?? 0)
        VWSCROLL {"p50_ms":\(String(format: "%.3f", p50)),"p95_ms":\(String(format: "%.3f", p95)),"p99_ms":\(String(format: "%.3f", p99)),"worst_ms":\(String(format: "%.3f", worst)),"frames":\(frames),"shaped_blocks":\(shaped)}

        """.utf8))
        exit(p95 <= 8.33 ? 0 : 2)
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
