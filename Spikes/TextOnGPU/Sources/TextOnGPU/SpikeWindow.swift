import AppKit
import Metal
import QuartzCore

// Windowed mode: Metal renderer on the left, NSTextView drawing the identical
// attributed string on the right. The two panes should be indistinguishable at
// reading distance. Keys: a = animate fractional offsets, l = light/dark, q = quit.

@MainActor
final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    private let smokeTest: Bool
    private var windowController: SpikeWindowController?

    init(smokeTest: Bool) {
        self.smokeTest = smokeTest
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = SpikeWindowController()
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if smokeTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("smoke OK")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class SpikeWindowController: NSWindowController {
    private var theme = Theme.dark
    private var metalView: MetalTextView!
    private var textView: NSTextView!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "vw P1 spike — Metal (left) vs NSTextView (right) · a: animate · l: theme · q: quit"
        window.center()
        super.init(window: window)

        metalView = MetalTextView(theme: theme)
        metalView.onKey = { [weak self] key in self?.handleKey(key) }

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true

        let stack = NSStackView(views: [metalView, scrollView])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        window.contentView = stack
        applyTheme()
        window.makeFirstResponder(metalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("spike builds UI in code")
    }

    private func handleKey(_ key: String) {
        switch key {
        case "a":
            metalView.animating.toggle()
        case "l":
            theme = theme.name == "dark" ? .light : .dark
            applyTheme()
        case "q":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func applyTheme() {
        metalView.theme = theme
        textView.backgroundColor = NSColor(cgColor: theme.background) ?? .textBackgroundColor
        textView.textStorage?.setAttributedString(SampleText.build(theme: theme))
        window?.backgroundColor = NSColor(cgColor: theme.background) ?? .textBackgroundColor
    }
}

@MainActor
final class MetalTextView: NSView {
    var theme: Theme {
        didSet { reshapeAndRender() }
    }
    var animating = false {
        didSet {
            displayLink?.isPaused = !animating
            if !animating { render(offset: .zero) }
        }
    }
    var onKey: ((String) -> Void)?

    private var renderer: GlyphRenderer?
    private var atlas: GlyphAtlas?
    private var shaped: ShapedText?
    private var displayLink: CADisplayLink?
    private let startTime = CACurrentMediaTime()

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("spike builds UI in code")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        return layer
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            onKey?(characters)
        } else {
            super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, renderer == nil else { return }
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        metalLayer.device = device
        renderer = try? GlyphRenderer(device: device)
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
        reshapeAndRender()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reshapeAndRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reshapeAndRender()
    }

    private func reshapeAndRender() {
        guard let window, let renderer, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        if let atlas, atlas.scale != scale {
            // The retina-flush path: moving to a display with a different scale
            // invalidates every rasterized bitmap.
            atlas.flush(scale: scale)
        } else if atlas == nil {
            atlas = GlyphAtlas(device: renderer.device, scale: scale)
        }
        shaped = shape(SampleText.build(theme: theme), wrapWidth: bounds.width, scale: scale)
        render(offset: .zero)
    }

    @objc private func tick() {
        // Slow drift with irrational-ish frequencies: every fractional x offset
        // (all four buckets) gets visited. Shimmer or weight pumping = failure.
        let t = CACurrentMediaTime() - startTime
        render(offset: CGPoint(x: sin(t * 0.9) * 6.3, y: cos(t * 0.53) * 4.1))
    }

    private func render(offset: CGPoint) {
        guard let renderer, let atlas, let shaped else { return }
        renderer.render(
            to: metalLayer, shaped: shaped, atlas: atlas,
            offset: offset, background: theme.background
        )
    }
}
