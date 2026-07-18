import Foundation
import Testing
import VWCore
import VWParse
import VWStyle
@testable import VWViewer

// Session-level editing: buffer→document convergence, dirty/commit/discard
// lifecycle, and the staleness guards that keep async work (highlights,
// background parses) from landing against a document that has moved.

private func oracle(_ data: Data) -> FlatDocument {
    flatten(parseMarkdown(data: data))
}

@Suite struct EditingSessionTests {
    @Test @MainActor func applyEditsRederivesDocumentAndTracksDirty() throws {
        let session = DocumentSession(data: Data("# Title\n\nHello world.\n".utf8), theme: .light)
        session.prepare(contentWidth: 600, scale: 2)
        var dirtyTransitions: [Bool] = []
        session.onDirtyChange = { dirtyTransitions.append($0) }

        let outcome = try session.applyEdits([
            SourceEdit(span: SourceSpan(startUTF8: 9, endUTF8: 14), replacement: "Goodbye"),
        ])
        #expect(outcome == .appliedFullReparse)
        #expect(String(decoding: session.data, as: UTF8.self) == "# Title\n\nGoodbye world.\n")
        #expect(session.isDirty)
        #expect(session.revision == 1)
        #expect(dirtyTransitions == [true])
        expectFlatDocumentsMatch(session.document!, oracle(session.data))
        // The layout was rebuilt against the new document.
        #expect(session.layout?.blockCount == session.document!.blocks.count)

        // Failed batches change nothing.
        #expect(throws: SourceEditError.self) {
            try session.applyEdits([
                SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 9999), replacement: "x"),
            ])
        }
        #expect(session.revision == 1)
        #expect(dirtyTransitions == [true])
    }

    @Test @MainActor func commitLifecycleSurvivesMidWriteEdits() throws {
        let session = DocumentSession(data: Data("alpha beta\n".utf8), theme: .light)
        session.prepare(contentWidth: 600, scale: 2)

        try session.applyEdits([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 5), replacement: "gamma")])
        let snapshot = session.commitSnapshot()
        #expect(String(decoding: snapshot.data, as: UTF8.self) == "gamma beta\n")
        #expect(snapshot.version == 1)

        // An edit lands while the App is writing the snapshot: committing the
        // snapshot's version must NOT clear dirty.
        try session.applyEdits([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 0), replacement: "> ")])
        session.markCommitted(version: snapshot.version)
        #expect(session.isDirty)

        // Committing the current version clears it.
        let fresh = session.commitSnapshot()
        session.markCommitted(version: fresh.version)
        #expect(!session.isDirty)
    }

    @Test @MainActor func discardRevertsToDiskTruthAndLandsClean() throws {
        let original = "# Doc\n\noriginal paragraph.\n"
        let session = DocumentSession(data: Data(original.utf8), theme: .light)
        session.prepare(contentWidth: 600, scale: 2)

        try session.applyEdits([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 5), replacement: "## Edited")])
        #expect(session.isDirty)
        let revisionBefore = session.revision

        session.discardEdits(to: Data(original.utf8))
        #expect(!session.isDirty)
        #expect(session.revision > revisionBefore)
        #expect(String(decoding: session.data, as: UTF8.self) == original)
        expectFlatDocumentsMatch(session.document!, oracle(session.data))
    }

    @Test @MainActor func editDuringSliceQueuesAndConverges() async throws {
        // Above the slice threshold the open path shows a prefix while the
        // full parse runs detached. An edit in that window must not be
        // obliterated when the (stale) parse lands.
        var text = ""
        while text.utf8.count <= firstPaintSliceThreshold {
            text += "A paragraph of reading text for the slice corpus.\n\n"
        }
        let session = DocumentSession(data: Data(text.utf8), theme: .light)
        session.prepare(contentWidth: 600, scale: 2)
        #expect(session.isSliced)

        // No main-actor yield since prepare(), so the detached parse cannot
        // have completed: the outcome is deterministically .queued.
        let outcome = try session.applyEdits([
            SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 0), replacement: "# EDITED\n\n"),
        ])
        #expect(outcome == .queued)

        // Only a version-fresh parse adopts and fires the splice: the stale
        // first result must be discarded and re-run against edited bytes.
        await withCheckedContinuation { continuation in
            session.onContentSplice = { continuation.resume() }
        }
        #expect(!session.isSliced)
        #expect(String(decoding: session.data.prefix(9), as: UTF8.self) == "# EDITED\n")
        expectFlatDocumentsMatch(session.document!, oracle(session.data))
        if case .heading = session.document!.blocks.first!.kind {} else {
            Issue.record("edited heading missing after slice convergence")
        }
    }

    @Test @MainActor func staleHighlightIsDroppedAfterEdit() async throws {
        let source = "# Doc\n\n```swift\nlet x = \"str\" + 42 // sum\n```\n\ntail paragraph.\n"
        let session = DocumentSession(data: Data(source.utf8), theme: .light)
        session.prepare(contentWidth: 600, scale: 2)
        let layout = try #require(session.layout)
        _ = layout.prepare(docRange: 0..<4000, anchorY: 0)
        let blocks = layout.placedBlocks(in: 0..<4000)

        // Positive control: without an edit, the async highlight lands.
        session.requestHighlights(for: blocks)
        await withCheckedContinuation { continuation in
            session.onContentUpdate = { continuation.resume() }
        }
        let codeIndex = session.document!.blocks.firstIndex { $0.kind == .codeBlock }!
        #expect(session.document!.blocks[codeIndex].runs.count > 1)
        session.onContentUpdate = nil

        // Now race a fresh highlight request against an edit. The edit bumps
        // the generation, so the in-flight lex must be dropped — its indices
        // and spans are in the pre-edit space.
        try session.applyEdits([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 0), replacement: "## New head\n\n")])
        let editedLayout = try #require(session.layout)
        _ = editedLayout.prepare(docRange: 0..<4000, anchorY: 0)
        session.requestHighlights(for: editedLayout.placedBlocks(in: 0..<4000))
        try session.applyEdits([SourceEdit(span: SourceSpan(startUTF8: 0, endUTF8: 0), replacement: "### Again\n\n")])

        // Give the stale lex ample time to land (it would apply via
        // onContentUpdate). The generation guard must keep runs plain.
        try await Task.sleep(for: .milliseconds(250))
        let editedCodeIndex = session.document!.blocks.firstIndex { $0.kind == .codeBlock }!
        #expect(session.document!.blocks[editedCodeIndex].runs.count == 1)

        // And a post-edit re-request highlights the right block again.
        let finalLayout = try #require(session.layout)
        _ = finalLayout.prepare(docRange: 0..<4000, anchorY: 0)
        session.requestHighlights(for: finalLayout.placedBlocks(in: 0..<4000))
        await withCheckedContinuation { continuation in
            session.onContentUpdate = { continuation.resume() }
        }
        let highlighted = session.document!.blocks[editedCodeIndex]
        #expect(highlighted.runs.count > 1)
        // Highlighted run spans must slice the CURRENT buffer to their text.
        let bytes = [UInt8](session.data)
        for run in highlighted.runs {
            guard let span = run.span else { continue }
            let sliced = String(decoding: bytes[span.startUTF8..<span.endUTF8], as: UTF8.self)
            #expect(sliced == run.text)
        }
    }

    @Test @MainActor func editableBytesCanonicalizesBeforeOffsetsAreExchanged() throws {
        // 0xFF is invalid UTF-8; the parse decoded it as U+FFFD (3 bytes), so
        // raw-byte offsets and span offsets disagree until canonicalization.
        let session = DocumentSession(data: Data([0x23, 0x20, 0xFF, 0x0A]), theme: .light) // "# \u{FFFD}\n"
        session.prepare(contentWidth: 600, scale: 2)
        let bytes = session.editableBytes()
        #expect(bytes == Data("# \u{FFFD}\n".utf8))
        #expect(session.data == bytes)
        // Spans from the pre-edit parse index the canonical bytes correctly.
        let heading = session.document!.blocks[0]
        #expect(heading.span.endUTF8 <= bytes.count)

        try session.applyEdits([SourceEdit(
            span: SourceSpan(startUTF8: bytes.count, endUTF8: bytes.count), replacement: "tail\n"
        )])
        expectFlatDocumentsMatch(session.document!, oracle(session.data))
    }
}

@Suite struct EditOracleTests {
    /// The centerpiece property: after any batch, the buffer byte-equals the
    /// naive reference and the session's document equals a fresh parse of the
    /// edited bytes — REGARDLESS of which path (bounded splice or full
    /// reparse) applied it. A divergence here is a boundary-picker bug.
    /// 30 seeds in CI (~0.3s); a 200-seed blast validated the corpus at
    /// implementation time — crank this range when touching the boundary
    /// picker.
    @Test(arguments: UInt64(1)...30) @MainActor func editedSessionMatchesFreshParse(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        let source = MarkdownGen.document(rng: &rng, blockCount: 18, includeRefDefs: seed % 5 == 0)
        let session = DocumentSession(data: Data(source.utf8), theme: .light)
        session.prepare(contentWidth: 600, scale: 2)

        for round in 0..<12 {
            let pre = session.editableBytes()
            let edits = MarkdownGen.editBatch(source: pre, rng: &rng)
            guard !edits.isEmpty else { continue }
            let expected = referenceApply(pre, edits)

            let outcome = try session.applyEdits(edits)
            #expect(
                outcome == .appliedFullReparse || outcome == .appliedBounded,
                "seed \(seed) round \(round)"
            )
            #expect(session.data == expected, "seed \(seed) round \(round)")
            guard expectFlatDocumentsMatch(
                session.document!, oracle(session.data), "seed \(seed) round \(round) outcome \(outcome)"
            ) else { return }
        }
    }

    /// The fallback must not silently eat the fast path: when the document is
    /// eligible (big enough, no ref-defs), most batches must take the bounded
    /// splice. Ineligible rounds (fuzz edits legally shrink documents below
    /// the small-doc cutoff, or introduce ref-defs) don't count against it.
    @Test @MainActor func boundedPathCarriesItsWeight() throws {
        var bounded = 0
        var eligible = 0
        for seed in UInt64(20)...29 {
            var rng = SeededRandom(seed: seed)
            let source = MarkdownGen.document(rng: &rng, blockCount: 40)
            let session = DocumentSession(data: Data(source.utf8), theme: .light)
            session.prepare(contentWidth: 600, scale: 2)
            for _ in 0..<10 {
                let pre = session.editableBytes()
                let wasEligible = session.document!.blocks.count >= 16
                    && !containsLinkReferenceDefinitions(pre)
                let edits = MarkdownGen.editBatch(source: pre, rng: &rng)
                guard !edits.isEmpty else { continue }
                let outcome = try session.applyEdits(edits)
                if wasEligible {
                    eligible += 1
                    if outcome == .appliedBounded { bounded += 1 }
                }
            }
        }
        // Measured ~46% on this corpus (the rest are LEGITIMATE fallbacks:
        // spread batches → windowTooLarge, edit-inserted unmatched fences
        // collapsing the doc). The floor is a starvation canary with margin,
        // not a target.
        #expect(eligible > 40)
        #expect(
            bounded * 100 >= eligible * 35,
            "bounded \(bounded)/\(eligible) eligible — the fast path is being starved by fallbacks"
        )
    }
}
