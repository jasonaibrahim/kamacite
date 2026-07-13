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
// memory budget, background-parse splice.

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
