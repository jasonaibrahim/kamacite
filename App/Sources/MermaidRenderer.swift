import AppKit
import VWViewer
import WebKit

/// App-side mermaid rasterizer: one offscreen WKWebView running the bundled
/// mermaid.js, shared by every document window.
///
/// Lifecycle invariants:
/// - Nothing WebKit-related happens at launch. The web view (and its host
///   window) exist only after the first `renderDiagram`/`warmUp` call, and are
///   torn down on timeout or web-process death so the next render starts fresh.
/// - Renders are strictly serialized (one shared DOM); duplicate in-flight keys
///   coalesce onto the same task; finished rasters live in a ~40MB LRU cache
///   that survives across documents (the app is a resident process).
/// - The page is untrusted document content: securityLevel 'strict', html
///   labels off, `baseURL: nil`, and every navigation after the initial
///   `loadHTMLString` is cancelled.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate, DiagramRendering {
    static let shared = MermaidRenderer()

    private static let renderTimeout: Duration = .seconds(10)
    private static let cacheCapBytes = 40 << 20
    /// Longest edge of the zoomed page we will snapshot. Keeps a runaway
    /// diagram from allocating an unbounded raster and stays well inside the
    /// Metal texture limit (16384).
    private static let maxZoomedEdgePx: CGFloat = 4096
    /// Not an FNV-1a output of any real request; the warm-up raster parks in
    /// the cache under this key and is simply never asked for again.
    private static let warmUpKey: UInt64 = 0

    /// The bundled mermaid build, read once (3.4MB). nil only if the app
    /// bundle is broken, in which case every render fails soft (blocks stay
    /// code blocks).
    private static let mermaidScriptSource: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private var webView: WKWebView?
    /// A WKWebView detached from any window can snapshot empty; a tiny
    /// never-ordered-front window parked far offscreen makes snapshots
    /// reliable without ever appearing on glass.
    private var hostWindow: NSWindow?
    /// Completes true once the harness page finished loading; shared so
    /// coalesced first renders wait on one load.
    private var harnessTask: Task<Bool, Never>?
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    /// True only between `loadHTMLString` and its completion — the navigation
    /// policy handler cancels everything else the page ever tries.
    private var allowHarnessLoad = false

    /// Tail of the serial render queue: each render awaits the previous one
    /// (single shared DOM; concurrent mermaid.render calls would interleave).
    private var queueTail: Task<Void, Never>?
    private var inFlight: [UInt64: Task<DiagramImage?, Never>] = [:]

    private struct CacheEntry {
        let image: DiagramImage
        let cost: Int
        var lastUse: UInt64
    }
    private var cache: [UInt64: CacheEntry] = [:]
    private var cacheCostBytes = 0
    private var useTick: UInt64 = 0

    private var warmedUp = false

    private override init() {
        super.init()
    }

    // MARK: - DiagramRendering

    func renderDiagram(_ request: DiagramRequest) async -> DiagramImage? {
        if let cached = cachedImage(forKey: request.key) {
            return cached
        }
        if let pending = inFlight[request.key] {
            return await pending.value
        }
        let task = Task { @MainActor in
            await self.serializedTimedRender(request)
        }
        inFlight[request.key] = task
        let image = await task.value
        inFlight[request.key] = nil
        if let image {
            insertCache(image, forKey: request.key)
        }
        return image
    }

    /// Pre-touches the whole pipeline — WebKit dyld link, web-process launch,
    /// harness load, first mermaid parse — so the first visible diagram pays
    /// only its own render. Call post-present, and only for documents that
    /// actually contain a mermaid fence.
    func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        Task { @MainActor in
            _ = await self.renderDiagram(DiagramRequest(
                key: Self.warmUpKey,
                source: "graph TD; A-->B",
                isDark: false,
                maxWidthPts: 600,
                pixelScale: NSScreen.main?.backingScaleFactor ?? 2
            ))
        }
    }

    // MARK: - Render pipeline

    private func serializedTimedRender(_ request: DiagramRequest) async -> DiagramImage? {
        let previous = queueTail
        let slot = Task { @MainActor () -> DiagramImage? in
            _ = await previous?.value
            return await self.timedRender(request)
        }
        queueTail = Task { @MainActor in _ = await slot.value }
        return await slot.value
    }

    private func timedRender(_ request: DiagramRequest) async -> DiagramImage? {
        let work = Task { @MainActor () -> DiagramImage? in
            await self.performRender(request)
        }
        enum Outcome: Sendable {
            case rendered(DiagramImage?)
            case timedOut
        }
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .rendered(await work.value) }
            group.addTask {
                try? await Task.sleep(for: MermaidRenderer.renderTimeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            if case .timedOut = first {
                // The page (or web process) is stuck; a hung
                // callAsyncJavaScript only resolves once the web view goes
                // away. Tear down HERE, while the render child is still
                // pending: the group cannot return until that child's await
                // of `work` completes, and the teardown is the only thing
                // that unblocks it. The next render starts fresh.
                work.cancel()
                tearDownWebView()
            }
            group.cancelAll()
            return first
        }
        switch outcome {
        case .rendered(let image):
            return image
        case .timedOut:
            return nil
        }
    }

    private func performRender(_ request: DiagramRequest) async -> DiagramImage? {
        guard let webView = await preparedWebView() else { return nil }

        // Measure at zoom 1 so the returned css size is zoom-independent.
        webView.pageZoom = 1
        let reply: Any?
        do {
            reply = try await webView.callAsyncJavaScript(
                "return await window.__renderMermaid(source, dark);",
                arguments: ["source": request.source, "dark": request.isDark],
                in: nil,
                contentWorld: .page
            )
        } catch {
            return nil // mermaid.render rejected (parse error) or JS failure
        }
        guard let dict = reply as? [String: Any],
              dict["ok"] as? Bool == true,
              let width = dict["width"] as? Double,
              let height = dict["height"] as? Double,
              width > 0, height > 0
        else { return nil }
        let cssSize = CGSize(width: width, height: height)

        // Raster headroom: zoom the page so the snapshot carries ~1 device px
        // per DISPLAYED px. The layout caps display width at the content
        // column, so cap the zoom identically — rasterizing an over-wide
        // diagram at intrinsic resolution would push it through the linear
        // sampler at >2x minification and thin strokes would drop out. When
        // the diagram fits the column this reduces to zoom == pixelScale.
        // Below 1 the page shrinks — acceptable softness for absurdly large
        // diagrams in exchange for bounded memory.
        let backingScale = request.fontScale > 0
            ? request.pixelScale / request.fontScale : request.pixelScale
        let displayWidthPts = min(cssSize.width * request.fontScale, request.maxWidthPts)
        var zoom = max(1, request.pixelScale)
        zoom = min(zoom, displayWidthPts * backingScale / cssSize.width)
        zoom = min(zoom, Self.maxZoomedEdgePx / max(cssSize.width, cssSize.height))
        guard zoom > 0.1 else { return nil }
        let zoomed = CGSize(
            width: ceil(cssSize.width * zoom),
            height: ceil(cssSize.height * zoom)
        )
        webView.pageZoom = zoom
        hostWindow?.setContentSize(zoomed)
        webView.frame = CGRect(origin: .zero, size: zoomed)

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: zoomed)
        config.afterScreenUpdates = true // waits for the zoom/resize to land
        config.snapshotWidth = NSNumber(value: Double(zoomed.width))
        // No generated async variant in this SDK (nullable image + nullable
        // error); errors collapse to nil either way.
        let snapshot: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let snapshot else { return nil }
        var proposedRect = CGRect(origin: .zero, size: snapshot.size)
        guard let cgImage = snapshot.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        else { return nil }

        // The pointSize contract: css px * fontScale, from the request itself —
        // never from the raster's pixel dimensions (snapshot scale semantics
        // are murky) and never from global screen state (the wrong screen on
        // mixed-DPI setups).
        let pointSize = CGSize(
            width: cssSize.width * request.fontScale,
            height: cssSize.height * request.fontScale
        )
        return DiagramImage(image: cgImage, pointSize: pointSize)
    }

    // MARK: - Web view lifecycle

    private func preparedWebView() async -> WKWebView? {
        let task: Task<Bool, Never>
        if let existing = harnessTask {
            task = existing
        } else {
            task = Task { @MainActor in await self.loadHarness() }
            harnessTask = task
        }
        // Renders are serialized, so nothing else mutates the web view while
        // we wait; a false here means the load failed (or was torn down).
        guard await task.value else {
            tearDownWebView()
            return nil
        }
        return webView
    }

    /// Blocks every network subresource. The navigation policy below only
    /// covers frame navigations — img/fetch/css loads sail past it, and
    /// mermaid has first-class syntax for remote images (flowchart image
    /// nodes), which untrusted document content must not be able to use as a
    /// beacon. The harness is fully self-contained, so nothing legitimate is
    /// lost.
    private static let blockAllNetworkRules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
        """

    private func loadHarness() async -> Bool {
        guard let mermaidSource = Self.mermaidScriptSource else { return false }
        // Fail closed: no rule list, no diagrams (blocks stay code blocks).
        guard let ruleList = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "kamacite-block-all-network",
            encodedContentRuleList: Self.blockAllNetworkRules
        ) else { return false }
        let controller = WKUserContentController()
        controller.add(ruleList)
        controller.addUserScript(WKUserScript(
            source: mermaidSource, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.harnessScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        webView.navigationDelegate = self
        // Transparent snapshots so rasters composite onto the document
        // background. WebKit's long-standing macOS escape hatch — there is no
        // public drawsBackground API on this platform.
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
        window.contentView = webView
        hostWindow = window

        allowHarnessLoad = true
        defer { allowHarnessLoad = false }
        return await withCheckedContinuation { continuation in
            loadContinuation = continuation
            webView.loadHTMLString(Self.harnessHTML, baseURL: nil)
        }
    }

    private func tearDownWebView() {
        loadContinuation?.resume(returning: false)
        loadContinuation = nil
        allowHarnessLoad = false
        webView?.navigationDelegate = nil
        webView = nil
        hostWindow?.contentView = nil
        hostWindow?.close()
        hostWindow = nil
        harnessTask = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        allowHarnessLoad ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume(returning: true)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(returning: false)
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        loadContinuation?.resume(returning: false)
        loadContinuation = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Jetsam or crash mid-render: pending JS calls error out, the current
        // render returns nil, and the next one rebuilds from scratch.
        tearDownWebView()
    }

    // MARK: - Cache

    private func cachedImage(forKey key: UInt64) -> DiagramImage? {
        guard var entry = cache[key] else { return nil }
        useTick += 1
        entry.lastUse = useTick
        cache[key] = entry
        return entry.image
    }

    private func insertCache(_ image: DiagramImage, forKey key: UInt64) {
        let cost = image.image.bytesPerRow * image.image.height
        if let old = cache.removeValue(forKey: key) {
            cacheCostBytes -= old.cost
        }
        useTick += 1
        cache[key] = CacheEntry(image: image, cost: cost, lastUse: useTick)
        cacheCostBytes += cost
        // O(n) LRU eviction; n stays in the tens under the byte cap. An entry
        // larger than the whole cap is allowed to sit alone.
        while cacheCostBytes > Self.cacheCapBytes, cache.count > 1 {
            guard let victim = cache.min(by: { $0.value.lastUse < $1.value.lastUse }),
                  victim.key != key
            else { break }
            cache.removeValue(forKey: victim.key)
            cacheCostBytes -= victim.value.cost
        }
    }

    // MARK: - Harness

    private static let harnessHTML = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
        html, body { margin: 0; padding: 0; background: transparent; }
        #container svg { display: block; }
        </style></head><body><div id="container"></div></body></html>
        """

    /// Injected after mermaid.min.js. `__renderMermaid` resolves with the
    /// diagram's intrinsic css-px size, or `{ok:false}` on any failure —
    /// mermaid.render rejects on parse errors and can leave an error element
    /// in the body, which the catch path removes.
    private static let harnessScript = """
        window.__renderMermaid = (() => {
            let counter = 0;
            return async (source, isDark) => {
                const container = document.getElementById('container');
                const id = 'm' + (++counter);
                try {
                    mermaid.initialize({
                        startOnLoad: false,
                        securityLevel: 'strict',
                        theme: isDark ? 'dark' : 'default',
                        htmlLabels: false,
                        flowchart: { htmlLabels: false },
                        class: { htmlLabels: false },
                        state: { htmlLabels: false }
                    });
                    const { svg } = await mermaid.render(id, source);
                    container.innerHTML = svg;
                    const el = container.querySelector('svg');
                    // Pin to intrinsic size: mermaid emits width:100% plus a
                    // max-width, which would tie the css size to our frame.
                    const vb = el.viewBox.baseVal;
                    if (vb && vb.width > 0 && vb.height > 0) {
                        el.style.maxWidth = 'none';
                        el.setAttribute('width', vb.width + 'px');
                        el.setAttribute('height', vb.height + 'px');
                    }
                    const box = el.getBoundingClientRect();
                    return { ok: true, width: box.width, height: box.height };
                } catch (err) {
                    container.innerHTML = '';
                    const orphan = document.getElementById('d' + id)
                        || document.getElementById(id);
                    if (orphan) orphan.remove();
                    return { ok: false, error: String((err && err.message) || err) };
                }
            };
        })();
        """
}
