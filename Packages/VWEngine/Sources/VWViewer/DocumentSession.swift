import Foundation
import QuartzCore
import VWLayout
import VWParse
import VWStyle

/// Owns one document's pipeline state: bytes → ContentTree → FlatDocument →
/// LazyLayout. Parse/flatten happen once; layout is viewport-lazy and reflows
/// on width/scale changes. All main-actor.
@MainActor
public final class DocumentSession {
    public let data: Data
    public private(set) var theme: Theme
    public private(set) var fonts: FontTable
    public private(set) var document: FlatDocument?
    public private(set) var layout: LazyLayout?

    /// Fired when async work (syntax highlighting) changed content that's
    /// already on glass — the view re-renders.
    public var onContentUpdate: (() -> Void)?
    /// Fired after the background full parse replaced a first-paint slice —
    /// the view re-anchors its scroll and re-renders. Layout has already been
    /// rebuilt when this fires.
    public var onContentSplice: (() -> Void)?
    /// App-injected mermaid rasterizer (offscreen WKWebView, set through the
    /// view). nil leaves mermaid fences as plain code blocks.
    public var diagramRenderer: DiagramRendering?
    /// Fired after applyDiagram swapped a block to `.diagram`: the VIEW
    /// finishes the job — texture upload and the anchored relayout — because
    /// the session knows neither the GPU device nor scroll state.
    public var onDiagramReady: ((Int, DiagramImage) -> Void)?
    /// Fired after a PENDING diagram (loading skeleton) fell back to a code
    /// block — render failure, or no renderer injected. The view runs the
    /// same anchored relayout as onDiagramReady, minus the texture.
    public var onDiagramFailed: ((Int) -> Void)?
    /// True while showing the slice of a huge document (full parse underway).
    public private(set) var isSliced = false
    private var fullParseStart: CFTimeInterval = 0
    // Internal get: tests assert mermaid blocks never enter the pipeline.
    private(set) var highlightRequested: Set<Int> = []
    private var diagramRequested: Set<Int> = []
    /// Indices with a render Task outstanding. The missing-texture path must
    /// skip these: buildFrame reports a pruned raster missing on EVERY frame
    /// until its replacement lands — without this, 120Hz would spawn a
    /// request storm at the renderer.
    private var diagramInFlight: Set<Int> = []
    /// Bumped whenever diagram request state is invalidated (theme flip, zoom,
    /// splice, backing-scale change). In-flight renders carry the generation
    /// they were requested under and drop their result on mismatch: completion
    /// order is not request order (the app renderer's cache returns instantly
    /// while a superseded render is still in its serialized queue), so without
    /// this a stale theme/zoom raster could land LAST and stick.
    private var diagramGeneration: UInt64 = 0

    public init(data: Data, theme: Theme) {
        self.data = data
        self.theme = theme
        self.fonts = FontTable(metrics: theme.metrics)
    }

    /// Parse/flatten once, then create (or reflow) the lazy layout. `mark`
    /// receives "parse"/"style"/"estimate" on the passes that ran.
    ///
    /// Huge documents take the first-paint slice: the opening ~256KB parses
    /// synchronously (glass in milliseconds), the whole document parses on a
    /// background task and splices in when ready.
    public func prepare(contentWidth: CGFloat, scale: CGFloat, mark: ((String) -> Void)? = nil) {
        if document == nil {
            if let sliceLength = firstPaintSliceLength(of: data) {
                let tree = parseMarkdown(data: data.prefix(sliceLength))
                mark?("parse")
                document = flatten(tree)
                mark?("style")
                isSliced = true
                scheduleFullParse()
            } else {
                let tree = parseMarkdown(data: data)
                mark?("parse")
                document = flatten(tree)
                mark?("style")
            }
        }
        guard let document else { return }

        if let layout {
            layout.reflow(contentWidth: contentWidth, scale: scale)
        } else {
            layout = LazyLayout(
                document: document, fonts: fonts, metrics: theme.metrics,
                contentWidth: contentWidth, scale: scale
            )
            mark?("estimate")
        }
    }

    // MARK: - First-paint slice

    private func scheduleFullParse() {
        fullParseStart = CACurrentMediaTime()
        let data = self.data
        Task.detached(priority: .userInitiated) { [weak self] in
            let tree = parseMarkdown(data: data)
            let flat = flatten(tree)
            await self?.completeFullParse(flat)
        }
    }

    private func completeFullParse(_ flat: FlatDocument) {
        guard isSliced else { return }
        isSliced = false
        document = flat
        // Highlight/diagram bookkeeping restarts against the full document's
        // indices (the splice shifted them).
        highlightRequested.removeAll()
        invalidateDiagramRasters()
        if let old = layout {
            layout = LazyLayout(
                document: flat, fonts: fonts, metrics: theme.metrics,
                contentWidth: old.contentWidth, scale: old.scale
            )
        }
        if ProcessInfo.processInfo.environment["VW_PERF"] == "1" {
            let elapsed = (CACurrentMediaTime() - fullParseStart) * 1000
            FileHandle.standardError.write(Data(String(
                format: "kama perf  splice  full document ready %+.0f ms after first paint (%d blocks)\n",
                elapsed, flat.blocks.count
            ).utf8))
        }
        onContentSplice?()
    }

    // MARK: - Async syntax highlighting

    /// Kick off highlighting for any visible code blocks that haven't been
    /// done yet. Lexing runs detached (user-sanctioned async — first paint
    /// shows plain code); results are color-only, so applying them re-shapes
    /// one block without moving layout.
    public func requestHighlights(for blocks: [BlockLayout]) {
        guard let document else { return }
        for placed in blocks where placed.kind == .codeBlock {
            let index = placed.flatIndex
            guard !highlightRequested.contains(index),
                  document.blocks.indices.contains(index) else { continue }
            let block = document.blocks[index]
            // Mermaid fences are diagrams-in-waiting: the placeholder shows
            // plain source until the raster lands, never highlighted. Not
            // marked requested — the block leaves the code path on swap.
            if isMermaidLanguage(block.codeLanguage) { continue }
            guard let language = block.codeLanguage, !language.isEmpty,
                  let plainRun = block.runs.first, block.runs.count == 1
            else {
                highlightRequested.insert(index)
                continue
            }
            highlightRequested.insert(index)
            let code = plainRun.text
            // The plain run's span is the byte-verified content span; tokens
            // inherit exact sub-spans so partial source copy stays byte-exact.
            let contentSpan = plainRun.span
            Task.detached(priority: .utility) { [weak self] in
                guard let runs = highlightCode(code, language: language, contentSpan: contentSpan) else { return }
                await self?.applyHighlight(index: index, runs: runs)
            }
        }
    }

    private func applyHighlight(index: Int, runs: [StyledRun]) {
        guard document != nil, document!.blocks.indices.contains(index) else { return }
        // Keep the session's copy (selection copy paths) and the layout's copy
        // (shaping) in sync.
        document!.blocks[index].runs = runs
        layout?.replaceRuns(at: index, with: runs)
        onContentUpdate?()
    }

    // MARK: - Async diagram rendering

    /// Kick off rasterization for visible mermaid blocks that haven't been
    /// requested yet. Runs during first paint too, so it may ONLY enqueue:
    /// the injected renderer is awaited on a Task and results land through
    /// applyDiagram → onDiagramReady. Accepts `.diagram` blocks as well —
    /// that's the refresh path after a theme flip cleared the request state.
    /// `missingTextureIndices` are visible `.diagram` blocks whose raster
    /// fell out of the view's texture store (pruning); their request state
    /// resets so they re-render.
    public func requestDiagrams(
        for blocks: [BlockLayout], pixelScale: CGFloat, fontScale: CGFloat = 1,
        missingTextureIndices: Set<Int> = []
    ) {
        guard let document, let layout else { return }
        guard let diagramRenderer else {
            // Engine used without an injected rasterizer: pending skeletons
            // resolve to code blocks instead of spinning forever. Deferred a
            // hop — this runs inside buildFrame, and the fallback's resize
            // callback must not mutate layout mid-frame.
            let pending = blocks.filter { $0.kind == .diagram }.map(\.flatIndex)
            if !pending.isEmpty {
                Task { [weak self] in
                    for index in pending { self?.fallbackDiagramToCode(index: index) }
                }
            }
            return
        }
        diagramRequested.subtract(missingTextureIndices.subtracting(diagramInFlight))
        for placed in blocks where placed.kind == .codeBlock || placed.kind == .diagram {
            let index = placed.flatIndex
            guard !diagramRequested.contains(index),
                  document.blocks.indices.contains(index) else { continue }
            let block = document.blocks[index]
            // Mark unconditionally (the requestHighlights pattern): non-mermaid
            // and multi-fragment blocks never become diagrams, so the language
            // check runs once per block, not once per frame.
            diagramRequested.insert(index)
            guard isMermaidLanguage(block.codeLanguage),
                  !block.isContinuation, !block.continues,
                  block.runs.count == 1, let run = block.runs.first
            else { continue }
            let source = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = CGFloat(block.indentLevel) * theme.metrics.indentWidth
            let request = DiagramRequest(
                key: diagramImageKey(source: source, isDark: theme.isDark, pixelScale: pixelScale),
                source: source,
                isDark: theme.isDark,
                maxWidthPts: max(40, layout.contentWidth - indent - theme.metrics.codeBlockPadding * 2),
                pixelScale: pixelScale,
                fontScale: fontScale
            )
            let sourceHash = fnv1a64(run.text)
            let generation = diagramGeneration
            diagramInFlight.insert(index)
            Task { [weak self] in
                let image = await diagramRenderer.renderDiagram(request)
                guard let self else { return }
                // Superseded generation: the invalidation already cleared the
                // in-flight mark (which now belongs to the replacement render,
                // if any) — drop everything, including the bookkeeping.
                guard generation == self.diagramGeneration else { return }
                self.diagramInFlight.remove(index)
                // nil (parse error / timeout): the skeleton degrades to a
                // code block. Still marked requested — never auto-retried
                // (the next theme flip / scale change retries naturally).
                guard let image else {
                    self.fallbackDiagramToCode(index: index, sourceHash: sourceHash)
                    return
                }
                self.applyDiagram(
                    index: index, sourceHash: sourceHash,
                    info: DiagramInfo(imageKey: request.key, naturalSizePts: image.pointSize),
                    image: image
                )
            }
        }
    }

    /// Land one rendered diagram. Staleness guards — the document may have
    /// been spliced between request and completion, shifting flat indices —
    /// require the block at `index` to still carry the same fence source
    /// (`.diagram` also passes: that's a theme/zoom refresh). Stale results
    /// drop silently; visibility re-requests them. Mutates ONLY kind +
    /// diagram: runs and spans keep the mermaid source so selection, copy,
    /// and VoiceOver never notice. Internal, not private: tests drive the
    /// staleness guard directly.
    func applyDiagram(index: Int, sourceHash: UInt64, info: DiagramInfo, image: DiagramImage) {
        guard document != nil, document!.blocks.indices.contains(index) else { return }
        let block = document!.blocks[index]
        guard block.kind == .codeBlock || block.kind == .diagram,
              isMermaidLanguage(block.codeLanguage),
              block.runs.count == 1, let run = block.runs.first,
              fnv1a64(run.text) == sourceHash
        else { return }
        document!.blocks[index].kind = .diagram
        document!.blocks[index].diagram = info
        // The layout's document copy is the VIEW's to update: the swap changes
        // block height, so it must route through the anchored replaceBlock
        // with the live viewport top.
        onDiagramReady?(index, image)
    }

    /// Rendering failed (or no renderer exists): a PENDING diagram degrades
    /// to a plain code block — the source is more honest than a skeleton that
    /// will never fill. Already-rendered diagrams keep their raster (a failed
    /// theme refresh shows stale ink rather than degrading to text). The
    /// optional source hash guards the async path against splices, same as
    /// applyDiagram; the synchronous no-renderer path has no such gap.
    private func fallbackDiagramToCode(index: Int, sourceHash: UInt64? = nil) {
        guard document != nil, document!.blocks.indices.contains(index) else { return }
        let block = document!.blocks[index]
        guard block.kind == .diagram, block.diagram == nil,
              isMermaidLanguage(block.codeLanguage) else { return }
        if let sourceHash {
            guard block.runs.count == 1, let run = block.runs.first,
                  fnv1a64(run.text) == sourceHash else { return }
        }
        document!.blocks[index].kind = .codeBlock
        onDiagramFailed?(index)
    }

    /// Palette-only theme swap: same metrics ⇒ same layout, pure re-render
    /// (the atlas lazily rasterizes flipped-polarity masks as needed). A theme
    /// with different metrics tears down layout — that's a font-size change,
    /// not an appearance flip.
    public func setTheme(_ newTheme: Theme) {
        let metricsChanged = newTheme.metrics != theme.metrics
        theme = newTheme
        // Diagrams re-render on ANY theme change: their ink is theme-colored
        // (text handles a palette flip as a pure re-render; diagrams are the
        // one case needing work), and a metrics change moves the pixel-scale
        // bucket. Swapped blocks keep the stale raster on glass until the
        // replacement lands.
        invalidateDiagramRasters()
        if metricsChanged {
            fonts = FontTable(metrics: newTheme.metrics)
            layout = nil
        }
    }

    /// Existing rasters no longer match the display state (theme flip, zoom,
    /// splice, backing-scale change): re-request visible diagrams and drop
    /// whatever superseded renders are still in flight when they land.
    public func invalidateDiagramRasters() {
        diagramRequested.removeAll()
        diagramInFlight.removeAll()
        diagramGeneration &+= 1
    }
}

/// Staleness token for in-flight diagram renders: deterministic FNV-1a 64
/// over the fence source (Hasher is seed-randomized per process).
private func fnv1a64(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}
