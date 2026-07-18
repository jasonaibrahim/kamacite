import CoreGraphics
import CoreText
import Foundation
import Metal
import Testing
import VWCore
import VWInteraction
import VWLayout
import VWParse
@testable import VWRender
@testable import VWStyle
@testable import VWViewer

// P8 robustness: first-paint slice safety, mega-paragraph splitting, atlas
// memory budget, background-parse splice, diagram session flow.

@Suite struct FirstPaintSliceTests {
    private func megabytes(_ n: Int, line: String = "A paragraph of reading text.\n\n") -> Data {
        var text = ""
        while text.utf8.count < n * 1024 * 1024 {
            text += line
        }
        return Data(text.utf8)
    }

    @Test func smallDocumentsDontSlice() {
        #expect(firstPaintSliceLength(of: Data("# small\n\ntext\n".utf8)) == nil)
        #expect(firstPaintSliceLength(of: megabytes(1) .prefix(1024)) == nil)
    }

    @Test func sliceCutsAtTopLevelBlankLine() {
        let data = megabytes(2)
        guard let length = firstPaintSliceLength(of: data) else {
            Issue.record("expected a slice for a 2MB document")
            return
        }
        #expect(length <= 256 * 1024 + 4096)
        #expect(length > 4096)
        // The byte before the cut is a newline ending a blank line.
        #expect(data[length - 1] == 0x0A)
        #expect(data[length - 2] == 0x0A)

        // Parsing slice then full must give identical leading blocks.
        let sliceTree = parseMarkdown(data: data.prefix(length))
        let slice = flatten(sliceTree)
        #expect(!slice.blocks.isEmpty)
    }

    @Test func sliceNeverCutsInsideAFence() {
        // ~200KB of prose, then a fence spanning the 256KB boundary: the cut
        // must land at a blank line BEFORE the fence opens.
        var text = ""
        while text.utf8.count < 200 * 1024 {
            text += "A steady paragraph of prose before the code arrives.\n\n"
        }
        text += "```swift\n"
        while text.utf8.count < 500 * 1024 {
            text += "let veryLongLine = \(text.utf8.count)\n"
        }
        text += "```\n\ntail paragraph\n"
        while text.utf8.count < (1 << 20) + 1 {
            text += "\npadding paragraph text here.\n"
        }
        let data = Data(text.utf8)
        guard let length = firstPaintSliceLength(of: data) else {
            Issue.record("expected a slice")
            return
        }
        let sliced = String(decoding: data.prefix(length), as: UTF8.self)
        let opens = sliced.components(separatedBy: "```").count - 1
        #expect(opens % 2 == 0, "cut left an unclosed fence (\(opens) markers)")
        #expect(length <= 210 * 1024, "cut should land before the fence opened")
    }

    @Test func degenerateDocumentRefusesToSlice() {
        // A giant fence opening near byte zero: no worthwhile safe cut exists,
        // so the correct (safe) answer is nil — parse the whole document.
        var text = "# T\n\n```\n"
        while text.utf8.count < (1 << 20) + 1024 {
            text += "fence content line \(text.utf8.count)\n"
        }
        text += "```\n"
        #expect(firstPaintSliceLength(of: Data(text.utf8)) == nil)
    }
}

@Suite struct MegaParagraphTests {
    @Test func hugeParagraphSplitsIntoContinuations() {
        let word = "supercalifragilistic "
        var text = ""
        while text.utf16.count < 200_000 {
            text += word
        }
        let doc = flatten(parseMarkdown(text))
        let fragments = doc.blocks
        #expect(fragments.count >= 3, "expected splitting, got \(fragments.count) blocks")
        #expect(fragments[0].isContinuation == false)
        #expect(fragments[0].continues == true)
        #expect(fragments.last?.isContinuation == true)
        #expect(fragments.last?.continues == false)
        for fragment in fragments {
            let length = fragment.runs.reduce(0) { $0 + $1.text.utf16.count }
            #expect(length <= 64 * 1024)
        }
        // Lossless: fragments rejoin to the rendered text (cmark trims the
        // paragraph's trailing whitespace).
        let rejoined = fragments.flatMap(\.runs).map(\.text).joined()
        let rendered = text.trimmingCharacters(in: .whitespaces)
        #expect(rejoined.utf16.count == rendered.utf16.count)
    }

    @Test func fragmentSpansPartitionExactly() {
        var text = ""
        while text.utf16.count < 100_000 {
            text += "words and more words to fill the paragraph out nicely "
        }
        let source = text.trimmingCharacters(in: .whitespaces)
        let doc = flatten(parseMarkdown(source))
        var expectedStart: Int?
        for block in doc.blocks {
            for run in block.runs {
                guard let span = run.span else { continue }
                if let expected = expectedStart {
                    #expect(span.startUTF8 == expected)
                }
                #expect(span.length == run.text.utf8.count)
                expectedStart = span.endUTF8
            }
        }
    }

    @Test @MainActor func copyAcrossFragmentsAddsNoNewlines() {
        var text = ""
        while text.utf16.count < 140_000 {
            text += "alpha beta gamma delta epsilon zeta eta theta iota kappa "
        }
        let doc = flatten(parseMarkdown(text))
        #expect(doc.blocks.count >= 2)
        let lastLength = doc.blocks.last!.runs.reduce(0) { $0 + ($1.text as NSString).length }
        let selection = DocumentSelection(
            anchor: TextPosition(blockIndex: 0, utf16Offset: 0),
            focus: TextPosition(blockIndex: doc.blocks.count - 1, utf16Offset: lastLength)
        )
        let copied = selectedPlainText(selection: selection, document: doc)
        #expect(!copied.contains("\n"), "fragment joins must not invent newlines")
    }

    @Test @MainActor func megaParagraphShapesQuickly() {
        var text = ""
        while text.utf16.count < 500_000 {
            text += "half a megabyte of a single unbroken paragraph flowing on "
        }
        let doc = flatten(parseMarkdown(text))
        let theme = Theme.light
        let start = Date()
        let layout = LazyLayout(
            document: doc, fonts: FontTable(metrics: theme.metrics),
            metrics: theme.metrics, contentWidth: 600, scale: 2
        )
        layout.prepare(docRange: 0..<1600, anchorY: 0)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "viewport shaping took \(elapsed)s")
        #expect(layout.shapedBlockCount < doc.blocks.count, "shaped everything — not lazy")
    }
}

@Suite struct AtlasBudgetTests {
    @Test @MainActor func atlasFlushesWhenOverPageBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let atlas = GlyphAtlas(device: device, scale: 2)
        let font = CTFontCreateUIFontForLanguage(.system, 48, nil)!
        let fontIndex = atlas.fontIndex(for: font)

        // Rasterize distinct glyph IDs at 4 buckets each until we exceed the
        // gray-page budget (big glyphs → few shelves per page).
        var glyph: CGGlyph = 100
        while atlas.grayPages.count <= GlyphAtlas.maxGrayPages, glyph < 3000 {
            for bucket in 0..<GlyphAtlas.subpixelBuckets {
                _ = atlas.entry(
                    fontIndex: fontIndex, glyph: glyph, bucket: bucket,
                    isColor: false, darkOnLight: false
                )
            }
            glyph += 1
        }
        #expect(atlas.grayPages.count > GlyphAtlas.maxGrayPages, "never exceeded budget — test setup wrong")

        #expect(atlas.flushIfOverBudget())
        #expect(atlas.grayPages.isEmpty)
        #expect(atlas.entryCount == 0)

        // The atlas works again after the flush.
        let entry = atlas.entry(fontIndex: fontIndex, glyph: 200, bucket: 0, isColor: false, darkOnLight: false)
        #expect(entry != nil)
        #expect(!atlas.flushIfOverBudget())
    }
}

@Suite struct SpliceTests {
    @Test @MainActor func hugeDocumentSplicesInFullParse() async throws {
        var text = "# Top heading\n\nOpening paragraph that stays stable.\n\n"
        while text.utf8.count < (1 << 20) + 200_000 {
            text += "Body paragraph number \(text.utf8.count) with steady content.\n\n"
        }
        let session = DocumentSession(data: Data(text.utf8), theme: .light)

        session.prepare(contentWidth: 600, scale: 2)
        #expect(session.isSliced, "expected the slice path for a >1MB document")
        let sliceBlocks = session.document!.blocks.count

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.onContentSplice = { continuation.resume() }
        }
        #expect(!session.isSliced)
        let fullBlocks = session.document!.blocks.count
        #expect(fullBlocks > sliceBlocks * 2, "full parse should dwarf the slice (\(sliceBlocks) → \(fullBlocks))")

        // Leading blocks are identical — the index-stable splice contract.
        let layout = session.layout
        #expect(layout != nil)
        #expect(layout!.blockCount == fullBlocks)
        let first = session.document!.blocks[0]
        #expect(first.kind == .heading(1))
    }
}

@Suite struct DiagramSessionTests {
    private static let markdown = """
    # Title

    Intro paragraph.

    ```mermaid
    graph TD
      A --> B
    ```

    ```swift
    let answer = 42
    ```

    Closing paragraph.
    """

    /// The spec's fake renderer: a tiny programmatic CGImage after a yield —
    /// no WKWebView anywhere in tests.
    @MainActor
    private final class FakeRenderer: DiagramRendering {
        var requests: [DiagramRequest] = []

        func renderDiagram(_ request: DiagramRequest) async -> DiagramImage? {
            requests.append(request)
            await Task.yield()
            guard let raster = Self.makeRaster() else { return nil }
            return DiagramImage(image: raster, pointSize: CGSize(width: 120, height: 80))
        }

        static func makeRaster() -> CGImage? {
            guard let context = CGContext(
                data: nil, width: 8, height: 8,
                bitsPerComponent: 8, bytesPerRow: 8 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return context.makeImage()
        }
    }

    /// Always fails: exercises the skeleton → code-block fallback.
    @MainActor
    private final class FailingRenderer: DiagramRendering {
        var requests = 0

        func renderDiagram(_ request: DiagramRequest) async -> DiagramImage? {
            requests += 1
            await Task.yield()
            return nil
        }
    }

    /// A renderer whose renders suspend until released, so tests control
    /// completion order — the real renderer's cache makes completion order
    /// diverge from request order, which is exactly what the generation
    /// guard exists for.
    @MainActor
    private final class GatedRenderer: DiagramRendering {
        var requests: [DiagramRequest] = []
        private var gates: [CheckedContinuation<Void, Never>?] = []

        func renderDiagram(_ request: DiagramRequest) async -> DiagramImage? {
            requests.append(request)
            await withCheckedContinuation { gates.append($0) }
            guard let raster = FakeRenderer.makeRaster() else { return nil }
            return DiagramImage(image: raster, pointSize: CGSize(width: 120, height: 80))
        }

        /// Releases the render that arrived `i`-th (0-based).
        func release(_ i: Int) {
            gates[i]?.resume()
            gates[i] = nil
        }
    }

    /// Bounded wait for detached request Tasks to reach the renderer; trips
    /// an #expect on timeout rather than hanging the suite.
    @MainActor
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }

    @MainActor
    private func makeSession() throws -> (session: DocumentSession, blocks: [BlockLayout], mermaidIndex: Int) {
        let session = DocumentSession(data: Data(Self.markdown.utf8), theme: .dark)
        session.prepare(contentWidth: 600, scale: 2)
        let layout = try #require(session.layout)
        layout.prepare(docRange: 0..<4000, anchorY: 0)
        let blocks = layout.placedBlocks(in: 0..<4000)
        let mermaidIndex = try #require(
            session.document?.blocks.firstIndex { isMermaidLanguage($0.codeLanguage) }
        )
        return (session, blocks, mermaidIndex)
    }

    @MainActor
    private func awaitDiagramReady(
        _ session: DocumentSession, trigger: () -> Void
    ) async -> Int {
        await withCheckedContinuation { continuation in
            session.onDiagramReady = { index, _ in continuation.resume(returning: index) }
            trigger()
        }
    }

    @Test @MainActor func mermaidBlockSwapsToDiagram() async throws {
        let (session, blocks, mermaidIndex) = try makeSession()
        let renderer = FakeRenderer()
        session.diagramRenderer = renderer
        let originalTexts = session.document!.blocks[mermaidIndex].runs.map(\.text)

        let (landedIndex, landedImage) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(Int, DiagramImage), Never>) in
            session.onDiagramReady = { continuation.resume(returning: ($0, $1)) }
            session.requestDiagrams(for: blocks, pixelScale: 2)
        }
        #expect(landedIndex == mermaidIndex)
        #expect(landedImage.pointSize == CGSize(width: 120, height: 80))

        let block = session.document!.blocks[mermaidIndex]
        #expect(block.kind == .diagram)
        let info = try #require(block.diagram)
        #expect(info.naturalSizePts == CGSize(width: 120, height: 80))
        let source = originalTexts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(info.imageKey == diagramImageKey(source: source, isDark: true, pixelScale: 2))
        // Runs/spans keep the fence source — selection/copy/VoiceOver never notice.
        #expect(block.runs.map(\.text) == originalTexts)

        // The mermaid fence was the only request, trimmed; a second visibility
        // pass enqueues nothing new.
        session.requestDiagrams(for: blocks, pixelScale: 2)
        #expect(renderer.requests.count == 1)
        #expect(renderer.requests.first?.source == source)
        #expect(renderer.requests.first?.isDark == true)
    }

    @Test @MainActor func staleResultIsDropped() throws {
        let (session, _, mermaidIndex) = try makeSession()
        var readyFired = false
        session.onDiagramReady = { _, _ in readyFired = true }
        let raster = try #require(FakeRenderer.makeRaster())
        let image = DiagramImage(image: raster, pointSize: CGSize(width: 120, height: 80))
        let info = DiagramInfo(imageKey: 7, naturalSizePts: CGSize(width: 120, height: 80))

        // Mismatched source hash — the document changed under the in-flight
        // render (a splice shifts flat indices) — must drop silently.
        session.applyDiagram(index: mermaidIndex, sourceHash: 0xDEAD_BEEF, info: info, image: image)
        // Out-of-bounds index: same silence.
        session.applyDiagram(index: 999, sourceHash: 0, info: info, image: image)

        // The block stays a pending skeleton (never swapped, never failed).
        #expect(session.document?.blocks[mermaidIndex].kind == .diagram)
        #expect(session.document?.blocks[mermaidIndex].diagram == nil)
        #expect(!readyFired)
    }

    @Test @MainActor func requestHighlightsSkipsMermaid() throws {
        let (session, blocks, mermaidIndex) = try makeSession()
        session.requestHighlights(for: blocks)
        #expect(!session.highlightRequested.contains(mermaidIndex))
        let swiftIndex = try #require(
            session.document?.blocks.firstIndex { $0.codeLanguage == "swift" }
        )
        #expect(session.highlightRequested.contains(swiftIndex))
    }

    /// A theme flip must re-render swapped diagrams (their ink is
    /// theme-colored) — setTheme clears request state and applyDiagram
    /// accepts an already-`.diagram` block as the refresh path.
    @Test @MainActor func themeFlipReRendersSwappedDiagram() async throws {
        let (session, blocks, mermaidIndex) = try makeSession()
        let renderer = FakeRenderer()
        session.diagramRenderer = renderer
        let first = await awaitDiagramReady(session) {
            session.requestDiagrams(for: blocks, pixelScale: 2)
        }
        #expect(first == mermaidIndex)

        session.setTheme(.light)
        let second = await awaitDiagramReady(session) {
            session.requestDiagrams(for: blocks, pixelScale: 2)
        }
        #expect(second == mermaidIndex)
        #expect(renderer.requests.count == 2)
        #expect(renderer.requests[1].isDark == false)
        let block = session.document!.blocks[mermaidIndex]
        #expect(block.kind == .diagram)
        let source = renderer.requests[1].source
        #expect(block.diagram?.imageKey
            == diagramImageKey(source: source, isDark: false, pixelScale: 2))
    }

    /// A visible `.diagram` block whose raster fell out of the view's texture
    /// store must re-render; while its replacement is in flight, the per-frame
    /// missing report must NOT spawn duplicates (120Hz request storm).
    @Test @MainActor func missingTextureReRequestsWithoutStorming() async throws {
        let (session, blocks, mermaidIndex) = try makeSession()
        let renderer = GatedRenderer()
        session.diagramRenderer = renderer
        session.requestDiagrams(for: blocks, pixelScale: 2)
        await settle { renderer.requests.count == 1 }

        // Pruned-texture report while the render is in flight: no duplicate.
        session.requestDiagrams(
            for: blocks, pixelScale: 2, missingTextureIndices: [mermaidIndex]
        )
        #expect(renderer.requests.count == 1)

        let first = await awaitDiagramReady(session) { renderer.release(0) }
        #expect(first == mermaidIndex)

        // With nothing in flight, the same report resets request state and
        // the diagram re-renders.
        session.requestDiagrams(
            for: blocks, pixelScale: 2, missingTextureIndices: [mermaidIndex]
        )
        await settle { renderer.requests.count == 2 }
        let second = await awaitDiagramReady(session) { renderer.release(1) }
        #expect(second == mermaidIndex)
    }

    /// Completion order is not request order (the app renderer's cache
    /// returns instantly while a superseded render sits in its serialized
    /// queue): a result from a superseded theme/zoom generation landing LAST
    /// must not overwrite the current raster.
    @Test @MainActor func supersededGenerationResultIsDropped() async throws {
        let (session, blocks, mermaidIndex) = try makeSession()
        let renderer = GatedRenderer()
        session.diagramRenderer = renderer
        var landings = 0
        session.requestDiagrams(for: blocks, pixelScale: 2) // dark, gen G
        await settle { renderer.requests.count == 1 }

        // Flip to light while the dark render is stuck: gen G+1 requested.
        session.setTheme(.light)
        session.requestDiagrams(for: blocks, pixelScale: 2)
        await settle { renderer.requests.count == 2 }

        // The light (current-generation) render completes first…
        let landed = await awaitDiagramReady(session) {
            renderer.release(1)
        }
        #expect(landed == mermaidIndex)
        session.onDiagramReady = { _, _ in landings += 1 }

        // …then the superseded dark render lands and must vanish without a
        // trace: no callback, key untouched.
        renderer.release(0)
        for _ in 0..<50 { await Task.yield() }
        #expect(landings == 0)
        let source = renderer.requests[1].source
        #expect(session.document!.blocks[mermaidIndex].diagram?.imageKey
            == diagramImageKey(source: source, isDark: false, pixelScale: 2))
    }

    /// Render failure: the pending skeleton degrades to a plain code block —
    /// the source is more honest than a skeleton that never fills.
    @Test @MainActor func renderFailureFallsBackToCodeBlock() async throws {
        let (session, blocks, mermaidIndex) = try makeSession()
        let renderer = FailingRenderer()
        session.diagramRenderer = renderer
        let failedIndex = await withCheckedContinuation { continuation in
            session.onDiagramFailed = { continuation.resume(returning: $0) }
            session.requestDiagrams(for: blocks, pixelScale: 2)
        }
        #expect(failedIndex == mermaidIndex)
        let block = session.document!.blocks[mermaidIndex]
        #expect(block.kind == .codeBlock)
        #expect(block.diagram == nil)
        // Language and runs survive: copy still works, and a theme flip's
        // request reset can retry the render.
        #expect(isMermaidLanguage(block.codeLanguage))
        #expect(!block.runs.isEmpty)
        #expect(renderer.requests == 1)
    }

    /// After a failure fallback, the retry a theme flip triggers can still
    /// upgrade the code block to a rendered diagram.
    @Test @MainActor func retryAfterFallbackUpgradesToDiagram() async throws {
        let (session, blocks, mermaidIndex) = try makeSession()
        session.diagramRenderer = FailingRenderer()
        _ = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
            session.onDiagramFailed = { c.resume(returning: $0) }
            session.requestDiagrams(for: blocks, pixelScale: 2)
        }
        #expect(session.document!.blocks[mermaidIndex].kind == .codeBlock)

        session.diagramRenderer = FakeRenderer()
        session.setTheme(.light)
        let landed = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
            session.onDiagramReady = { index, _ in c.resume(returning: index) }
            session.requestDiagrams(for: blocks, pixelScale: 2)
        }
        #expect(landed == mermaidIndex)
        #expect(session.document!.blocks[mermaidIndex].kind == .diagram)
        #expect(session.document!.blocks[mermaidIndex].diagram != nil)
    }

    /// Engine used without an injected renderer: skeletons resolve to code
    /// blocks (deferred off the frame path), once.
    @Test @MainActor func noRendererFallsBackToCodeBlock() async throws {
        let (session, blocks, mermaidIndex) = try makeSession()
        var failed: [Int] = []
        let first = await withCheckedContinuation { continuation in
            session.onDiagramFailed = {
                failed.append($0)
                continuation.resume(returning: $0)
            }
            session.requestDiagrams(for: blocks, pixelScale: 2)
        }
        #expect(first == mermaidIndex)
        #expect(session.document!.blocks[mermaidIndex].kind == .codeBlock)
        // Idempotent: the next frame's call (with stale placed kinds) is a
        // no-op — the block already fell back.
        session.requestDiagrams(for: blocks, pixelScale: 2)
        for _ in 0..<50 { await Task.yield() }
        #expect(failed == [mermaidIndex])
    }

    /// A fence past the flattener's 64KB chunking limit becomes continuation
    /// fragments, each holding only part of the source — none may ever reach
    /// the renderer.
    @Test @MainActor func fragmentedMermaidFenceIsNeverRequested() async throws {
        var body = "```mermaid\ngraph TD\n"
        var i = 0
        while body.utf16.count <= 70_000 {
            body += "  N\(i) --> N\(i + 1)\n"
            i += 1
        }
        body += "\n```"
        let session = DocumentSession(data: Data(body.utf8), theme: .dark)
        session.prepare(contentWidth: 600, scale: 2)
        let layout = try #require(session.layout)
        let fragments = session.document!.blocks.filter { isMermaidLanguage($0.codeLanguage) }
        #expect(fragments.count >= 2)
        #expect(fragments.first?.continues == true)

        layout.prepare(docRange: 0..<layout.contentHeightPts, anchorY: 0)
        let blocks = layout.placedBlocks(in: 0..<layout.contentHeightPts)
        let renderer = FakeRenderer()
        session.diagramRenderer = renderer
        session.requestDiagrams(for: blocks, pixelScale: 2)
        for _ in 0..<50 { await Task.yield() }
        #expect(renderer.requests.isEmpty)
    }
}
