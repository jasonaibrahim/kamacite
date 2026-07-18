import CoreGraphics

// The seam between the engine and the app's mermaid rasterizer. The engine
// stays WebKit-free: the app injects a DiagramRendering (offscreen WKWebView +
// bundled mermaid.js) through DocumentEngineView, and the session talks to it
// only through these value types.

/// One diagram rasterization request. `key` == diagramImageKey(source:isDark:pixelScale:).
public struct DiagramRequest: Sendable {
    public let key: UInt64
    /// Trimmed mermaid source (the fence content).
    public let source: String
    public let isDark: Bool
    /// Current content width available to the block, points.
    public let maxWidthPts: CGFloat
    /// backingScaleFactor * current fontScale.
    public let pixelScale: CGFloat
    /// Current fontScale (Cmd+/- zoom), carried separately so the renderer can
    /// honor the pointSize contract (css px * fontScale) without recovering it
    /// from global screen state — NSScreen.main is the wrong screen whenever
    /// the requesting window sits on a different-DPI display.
    public let fontScale: CGFloat

    public init(
        key: UInt64, source: String, isDark: Bool,
        maxWidthPts: CGFloat, pixelScale: CGFloat, fontScale: CGFloat = 1
    ) {
        self.key = key
        self.source = source
        self.isDark = isDark
        self.maxWidthPts = maxWidthPts
        self.pixelScale = pixelScale
        self.fontScale = fontScale
    }
}

/// Immutable raster handed back by the app-side renderer. CGImage is
/// immutable → safe to send.
public struct DiagramImage: @unchecked Sendable {
    public let image: CGImage
    /// Display size in points at the zoom level of the request
    /// (css px * fontScale — NOT derived from the raster's pixel size).
    public let pointSize: CGSize

    public init(image: CGImage, pointSize: CGSize) {
        self.image = image
        self.pointSize = pointSize
    }
}

/// Implemented by the App target (offscreen WKWebView + bundled mermaid.js).
/// Main-actor: WKWebView is main-thread-only and the session is @MainActor
/// anyway.
@MainActor public protocol DiagramRendering: AnyObject {
    /// nil on parse error / timeout — the block then stays a code block.
    func renderDiagram(_ request: DiagramRequest) async -> DiagramImage?
}
