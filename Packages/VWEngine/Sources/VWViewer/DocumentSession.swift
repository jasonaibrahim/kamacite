import Foundation
import QuartzCore
import VWCore
import VWLayout
import VWParse
import VWStyle

/// Owns one document's pipeline state: bytes → ContentTree → FlatDocument →
/// LazyLayout. Parse/flatten happen once for a read-only session; layout is
/// viewport-lazy and reflows on width/scale changes. Live edits mutate the
/// source through `applyEdits`, which re-derives the document (bounded splice
/// where possible, full reparse as the detected fallback) — the file on disk
/// is untouched until the App commits. All main-actor.
@MainActor
public final class DocumentSession {
    /// The live bytes: the mmap'd file until the first edit, the mutable
    /// buffer's contents after. Every SourceSpan in `document` indexes into
    /// this (the one invariant editing must never break — except while a
    /// version-guarded background parse is catching up to the buffer).
    public private(set) var data: Data
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
    /// Fired after a bounded edit splice updated the session's document. The
    /// VIEW finishes the job — it splices its layout copy (anchored to the
    /// live viewport top, which the session doesn't know), remaps selection,
    /// prunes textures, and renders.
    public var onContentEdit: ((ContentEditSplice) -> Void)?
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

    // MARK: - Editing state

    /// Created on first edit (or first `editableBytes()` call) so read-only
    /// opens keep the mmap and pay nothing.
    private var sourceBuffer: SourceBuffer?
    /// Buffer version at the last commit/discard; dirty is derived, never
    /// stored, so edits landing mid-commit can't be lost by a flag race.
    private var lastCommittedVersion: UInt64 = 0
    public var isDirty: Bool { revision != lastCommittedVersion }
    /// The wire-visible revision: 0 until the first edit, then the buffer's
    /// version. The IPC layer CASes against this.
    public var revision: UInt64 { sourceBuffer?.version ?? 0 }
    /// Fired on every dirty-state transition (the App wires the window's
    /// edited dot to this through the view).
    public var onDirtyChange: ((Bool) -> Void)?
    /// True while an edit-triggered detached full reparse is running. Distinct
    /// from `isSliced` (the first-open slice) but serialized the same way:
    /// edits arriving while either is set only touch the buffer (`.queued`),
    /// and the version guard restarts the parse until it lands fresh.
    private var fullReparseInFlight = false
    /// Whether the document contains link reference definitions — the one
    /// construct whose effect is document-global, so its presence gates EVERY
    /// edit to the full-reparse path. Scanned on first edit, re-scanned after
    /// each full reparse (a bounded splice can't introduce one: the chunk is
    /// scanned inside computeEditSplice).
    private var referenceDefinitionsPresent: Bool?
    /// BlockID base for bounded chunk parses, advanced past every minted ID
    /// so partial parses never collide with the full parse's IDs (which mint
    /// from 0) or each other's. Nothing keys on BlockID today; this keeps it
    /// that way safely.
    private var nextBlockIDBase: UInt64 = 1 << 32

    // Internal get: tests assert mermaid blocks never enter the pipeline.
    private(set) var highlightRequested: Set<Int> = []
    /// Bumped whenever flat indices shift (edit splice, full reparse, slice
    /// splice). In-flight highlight lexes carry the generation they were
    /// requested under and drop on mismatch — without this, a stale lex would
    /// overwrite a DIFFERENT block's runs (bounds checks can't catch an index
    /// that shifted onto another block).
    private var highlightGeneration: UInt64 = 0
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

    // MARK: - Live editing

    /// What `applyEdits` did with the batch. The buffer always has the edit
    /// on return; the on-screen document may still be catching up.
    public enum EditApplyOutcome: Equatable, Sendable {
        /// Bounded splice landed; `onContentEdit` fired.
        case appliedBounded
        /// Synchronous full-reparse fallback landed; `onContentSplice` fired.
        case appliedFullReparse
        /// Large document: a version-guarded detached full reparse is running;
        /// `onContentSplice` fires when it lands against fresh bytes.
        case scheduledFullReparse
        /// A parse was already in flight (first-open slice or a prior edit's
        /// reparse). Its version guard will restart it against these bytes.
        case queued
    }

    /// Apply a batch of non-overlapping byte-range edits to the in-memory
    /// buffer and re-derive the on-screen document. Atomic: throws
    /// `SourceEditError` with nothing changed. `mark` receives
    /// "buffer"/"parse"/"style" on the stages that ran synchronously.
    @discardableResult
    public func applyEdits(_ edits: [SourceEdit], mark: ((String) -> Void)? = nil) throws -> EditApplyOutcome {
        let dirtyBefore = isDirty
        defer { if isDirty != dirtyBefore { onDirtyChange?(isDirty) } }

        ensureSourceBuffer()
        let wasCanonicalized = sourceBuffer!.wasCanonicalized
        if referenceDefinitionsPresent == nil {
            // Scanned over PRE-edit bytes deliberately: an edit that deletes
            // the document's only definition must still route to the full
            // reparse (references elsewhere lose their target), whose rescan
            // then clears the gate.
            referenceDefinitionsPresent = containsLinkReferenceDefinitions(data)
        }
        let summary = try sourceBuffer!.apply(edits)
        data = sourceBuffer!.data
        mark?("buffer")

        if isSliced || fullReparseInFlight || document == nil {
            return .queued
        }
        if wasCanonicalized, revision == 1 {
            // First edit on a canonicalized buffer: existing spans predate
            // the healing swap — re-derive everything once.
            return performFullReparse(mark: mark)
        }
        if referenceDefinitionsPresent! {
            return performFullReparse(mark: mark)
        }

        switch computeEditSplice(
            document: document!, postEditData: data,
            summary: summary, mintingIDsFrom: nextBlockIDBase
        ) {
        case .splice(let splice):
            mark?("parse")
            // The flattener stamps childless list items with the .max
            // sentinel ID — skip it or the advance overflows.
            let maxMinted = splice.newBlocks.map(\.id.rawValue)
                .filter { $0 != .max }.max()
            nextBlockIDBase = max(nextBlockIDBase, (maxMinted ?? nextBlockIDBase) &+ 1)
            applyEditSplice(splice, to: &document!)
            mark?("style")
            // Flat indices moved: async work in flight is stale, index-keyed
            // request state restarts (the adoptReparsedDocument contract,
            // minus the layout rebuild — the view splices its layout copy
            // through onContentEdit instead).
            highlightRequested.removeAll()
            highlightGeneration &+= 1
            invalidateDiagramRasters()
            onContentEdit?(splice)
            return .appliedBounded
        case .fullReparse:
            return performFullReparse(mark: mark)
        }
    }

    /// The buffer's bytes, materializing the buffer first. The IPC layer must
    /// resolve find/replace matches and serve reads through THIS (not `data`)
    /// so that an invalid-UTF-8 file is canonicalized before any offsets are
    /// exchanged — offsets into the raw bytes would be in a different space.
    public func editableBytes() -> Data {
        ensureSourceBuffer()
        return data
    }

    /// Cheap length for status-style responses: `editableBytes()` would
    /// materialize the buffer (a one-time O(n) validation scan that page
    /// faults the whole mmap) — a `status` on a 100MB document shouldn't.
    public var byteCount: Int { data.count }

    /// Preview support: raise exactly the errors `applyEdits` would, mutate
    /// nothing.
    public func validateEdits(_ edits: [SourceEdit]) throws {
        ensureSourceBuffer()
        try sourceBuffer!.validate(edits)
    }

    private func ensureSourceBuffer() {
        guard sourceBuffer == nil else { return }
        sourceBuffer = SourceBuffer(data: data)
        if sourceBuffer!.wasCanonicalized {
            // The parse already lives in decoded-string space, which IS the
            // canonical byte space — swapping `data` heals the historical
            // span-vs-raw-bytes divergence rather than creating one.
            data = sourceBuffer!.data
        }
    }

    // MARK: - Commit / discard

    /// Bytes to persist plus their version. The App writes atomically
    /// (temp + rename — the original inode must survive for live mmaps) and
    /// reports back through `markCommitted`.
    public func commitSnapshot() -> (data: Data, version: UInt64) {
        (data, revision)
    }

    /// The App finished writing `version`'s bytes. Dirty clears only if no
    /// edits landed during the write.
    public func markCommitted(version: UInt64) {
        let dirtyBefore = isDirty
        lastCommittedVersion = version
        if isDirty != dirtyBefore { onDirtyChange?(isDirty) }
    }

    /// Revert the buffer to the App's disk-truth snapshot. Counts as a
    /// revision (in-flight parses and IPC clients must see the world moved),
    /// lands clean, and re-derives the document.
    public func discardEdits(to diskData: Data) {
        let dirtyBefore = isDirty
        ensureSourceBuffer()
        sourceBuffer!.replaceAll(with: diskData)
        data = sourceBuffer!.data
        lastCommittedVersion = sourceBuffer!.version
        if isDirty != dirtyBefore { onDirtyChange?(isDirty) }
        guard !isSliced, !fullReparseInFlight, document != nil else { return }
        _ = performFullReparse(mark: nil)
    }

    // MARK: - Full-reparse fallback

    private func performFullReparse(mark: ((String) -> Void)?) -> EditApplyOutcome {
        if data.count <= firstPaintSliceThreshold {
            let tree = parseMarkdown(data: data)
            mark?("parse")
            let flat = flatten(tree)
            mark?("style")
            adoptReparsedDocument(flat)
            return .appliedFullReparse
        }
        scheduleEditFullReparse()
        return .scheduledFullReparse
    }

    /// Convergence note: a stale result restarts against the CURRENT bytes,
    /// so a continuous edit stream faster than one full parse keeps the
    /// screen lagging until a quiet window arrives. Fine for turn-based
    /// agents (this path only runs on large ref-def/fallback documents);
    /// revisit with incremental catch-up if streaming editors appear.
    private func scheduleEditFullReparse() {
        fullReparseInFlight = true
        let snapshot = data
        let version = revision
        Task.detached(priority: .userInitiated) { [weak self] in
            let flat = flatten(parseMarkdown(data: snapshot))
            await self?.completeEditFullReparse(flat, version: version)
        }
    }

    private func completeEditFullReparse(_ flat: FlatDocument, version: UInt64) {
        guard version == revision else {
            // The buffer moved while parsing: this result would silently
            // revert the newer edits on glass. Re-run against current bytes.
            scheduleEditFullReparse()
            return
        }
        fullReparseInFlight = false
        adoptReparsedDocument(flat)
    }

    /// Install a freshly parsed document: flat indices are new, so every
    /// index-keyed structure restarts and in-flight async work goes stale.
    private func adoptReparsedDocument(_ flat: FlatDocument) {
        document = flat
        // A full pass is the one moment a stale ref-def gate can clear (the
        // bounded path can only ever set it).
        referenceDefinitionsPresent = containsLinkReferenceDefinitions(data)
        highlightRequested.removeAll()
        highlightGeneration &+= 1
        invalidateDiagramRasters()
        if let old = layout {
            layout = LazyLayout(
                document: flat, fonts: fonts, metrics: theme.metrics,
                contentWidth: old.contentWidth, scale: old.scale
            )
        }
        onContentSplice?()
    }

    // MARK: - First-paint slice

    private func scheduleFullParse() {
        fullParseStart = CACurrentMediaTime()
        let data = self.data
        let version = revision
        Task.detached(priority: .userInitiated) { [weak self] in
            let tree = parseMarkdown(data: data)
            let flat = flatten(tree)
            await self?.completeFullParse(flat, version: version)
        }
    }

    private func completeFullParse(_ flat: FlatDocument, version: UInt64) {
        guard isSliced else { return }
        guard version == revision else {
            // An edit landed while the background parse ran: adopting this
            // result would revert it on glass while the buffer keeps it — the
            // next span-anchored edit would then corrupt. Stay sliced and
            // re-parse the current bytes.
            scheduleFullParse()
            return
        }
        isSliced = false
        document = flat
        // Highlight/diagram bookkeeping restarts against the full document's
        // indices (the splice shifted them).
        highlightRequested.removeAll()
        highlightGeneration &+= 1
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
            let generation = highlightGeneration
            Task.detached(priority: .utility) { [weak self] in
                guard let runs = highlightCode(code, language: language, contentSpan: contentSpan) else { return }
                await self?.applyHighlight(index: index, runs: runs, generation: generation)
            }
        }
    }

    private func applyHighlight(index: Int, runs: [StyledRun], generation: UInt64) {
        // Stale generation: the document was re-derived (edit/reparse/splice)
        // after this lex was requested — `index` may now be a different block,
        // and the runs' spans are in the old byte space. Bounds checks alone
        // cannot catch either. Drop; visibility re-requests.
        guard generation == highlightGeneration else { return }
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
