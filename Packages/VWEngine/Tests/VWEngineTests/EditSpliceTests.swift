import Foundation
import Testing
import VWCore
import VWParse
import VWStyle

// Targeted computeEditSplice cases: each names a way markdown's context
// sensitivity could break a bounded reparse. Every case runs the same
// verification — splice the pre-edit document and compare against a fresh
// whole-document parse — so a passing test proves the window was WIDE ENOUGH,
// and the outcome assertions prove it wasn't trivially the fallback.

private enum Applied {
    case bounded(blockRange: Range<Int>)
    case fullReparse(EditFallbackReason)
}

/// Apply `edits` to `source` through the bounded machinery and verify the
/// spliced document equals the oracle. Returns which path ran.
@discardableResult
private func verify(
    _ source: String, _ edits: [SourceEdit],
    _ context: String = "", padTo minBlocks: Int = 16
) throws -> Applied {
    // Pad with trailing paragraphs so the small-document guard doesn't hide
    // the case under test (edits target the ORIGINAL byte range, unaffected).
    var padded = source
    let sourceBytes = padded.utf8.count
    while flatten(parseMarkdown(padded)).blocks.count < minBlocks {
        padded += "\n\nPadding paragraph to clear the small-document guard."
    }
    _ = sourceBytes

    var document = flatten(parseMarkdown(padded))
    var buffer = SourceBuffer(data: Data(padded.utf8))
    let summary = try buffer.apply(edits)

    switch computeEditSplice(
        document: document, postEditData: buffer.data,
        summary: summary, mintingIDsFrom: 1 << 32
    ) {
    case .splice(let splice):
        applyEditSplice(splice, to: &document)
        expectFlatDocumentsMatch(
            document, flatten(parseMarkdown(data: buffer.data)), context
        )
        return .bounded(blockRange: splice.blockRange)
    case .fullReparse(let reason):
        return .fullReparse(reason)
    }
}

private func edit(_ start: Int, _ end: Int, _ text: String) -> SourceEdit {
    SourceEdit(span: SourceSpan(startUTF8: start, endUTF8: end), replacement: text)
}

/// Byte offset of `needle` in `haystack` (first occurrence).
private func offset(of needle: String, in haystack: String) -> Int {
    let bytes = Array(haystack.utf8)
    let target = Array(needle.utf8)
    for start in 0...(bytes.count - target.count)
        where Array(bytes[start..<(start + target.count)]) == target {
        return start
    }
    Issue.record("needle '\(needle)' not found")
    return 0
}

@Suite struct EditSpliceTests {
    let base = """
    # Title

    First paragraph with some words in it.

    Second paragraph, also with words.

    ```swift
    let x = 1
    let y = 2
    ```

    Third paragraph after the fence.
    """

    @Test func midParagraphEditStaysNarrow() throws {
        let at = offset(of: "also", in: base)
        let applied = try verify(base, [edit(at, at + 4, "additionally")], "mid-paragraph")
        guard case .bounded(let range) = applied else {
            Issue.record("expected bounded")
            return
        }
        // One edited block plus its two guard neighbors.
        #expect(range.count <= 3)
    }

    @Test func editInsideFenceStaysBounded() throws {
        let at = offset(of: "let y = 2", in: base)
        let applied = try verify(base, [edit(at, at + 9, "let y = 99 // edited")], "fence-interior")
        guard case .bounded = applied else {
            Issue.record("expected bounded")
            return
        }
    }

    @Test func deletingFenceCloserSwallowsHonestly() throws {
        // Deleting the ``` closer makes the fence swallow the rest of the
        // document — the parity scan must widen to EOF, not splice locally.
        let at = offset(of: "```\n\nThird", in: base)
        try verify(base, [edit(at, at + 3, "")], "fence-closer-delete")
    }

    @Test func insertingFenceOpenerSwallowsHonestly() throws {
        let at = offset(of: "Second", in: base)
        try verify(base, [edit(at, at, "```\n")], "fence-opener-insert")
    }

    @Test func insertingSetextUnderlineConvertsTheParagraphAbove() throws {
        let source = "Alpha paragraph.\n\nBeta paragraph.\n\nGamma paragraph."
        // Appending an === line directly under Beta turns it into a heading.
        let at = offset(of: "\n\nGamma", in: source)
        try verify(source, [edit(at, at, "\n===")], "setext-insert")
        // And ---: a thematic break OR setext h2 depending on the blank line.
        try verify(source, [edit(at, at, "\n---")], "setext-dash-insert")
        try verify(source, [edit(at, at, "\n\n---")], "rule-insert")
    }

    @Test func deletingBlankLineMergesNeighbors() throws {
        let source = "One paragraph here.\n\nTwo paragraph here.\n\nThree paragraph here."
        let at = offset(of: ".\n\nTwo", in: source)
        // Deleting the gap's blank line lazily continues One into Two.
        try verify(source, [edit(at + 1, at + 3, " ")], "blank-line-delete")
    }

    @Test func listEditsRenumberTheWholeList() throws {
        let source = """
        Intro paragraph.

        1. first item
        2. second item
        3. third item

        Outro paragraph.
        """
        // Deleting item 2 renumbers item 3 — the whole list must re-derive.
        let at = offset(of: "2. second item\n", in: source)
        try verify(source, [edit(at, at + 15, "")], "ordered-delete")
        // Inserting a new first item shifts every number after it.
        let top = offset(of: "1. first", in: source)
        try verify(source, [edit(top, top, "1. zeroth item\n")], "ordered-insert")
    }

    @Test func tableCellEditRederivesTheTable() throws {
        let source = """
        Before table.

        | alpha | beta |
        | --- | ---: |
        | a1 | b1 |
        | a2 | b2 |

        After table.
        """
        let at = offset(of: "b1", in: source)
        try verify(source, [edit(at, at + 2, "EDITED CELL")], "table-cell")
        // Deleting the delimiter row demotes the table to paragraphs.
        let delim = offset(of: "| --- | ---: |\n", in: source)
        try verify(source, [edit(delim, delim + 15, "")], "table-delimiter-delete")
    }

    @Test func editFarBelowATableShiftsItsIndicesCorrectly() throws {
        // The classic suffix trap in reverse: table BEFORE the edit — its
        // firstRowFlatIndex must survive; and table AFTER the edit — its
        // index must shift when the edit changes the block count.
        let source = """
        | h1 | h2 |
        | -- | -- |
        | x | y |

        Middle paragraph one.

        Middle paragraph two.

        | j1 | j2 |
        | -- | -- |
        | p | q |

        Tail paragraph.
        """
        let at = offset(of: "Middle paragraph one.", in: source)
        // Replace one paragraph with three (block count +2 between tables).
        try verify(
            source,
            [edit(at, at + 21, "Grown one.\n\nGrown two.\n\nGrown three.")],
            "table-suffix-shift"
        )
    }

    @Test func blockquoteEditsGroupTheQuote() throws {
        let source = """
        Plain lead.

        > quoted first line
        lazy continuation of the quote
        > quoted third line

        Plain tail.
        """
        let at = offset(of: "lazy", in: source)
        try verify(source, [edit(at, at + 4, "LAZY")], "quote-lazy-edit")
        // Turning the continuation into a blank line splits the quote.
        try verify(source, [edit(at, at + 30, "")], "quote-continuation-delete")
    }

    @Test func indentedCodeAdjacency() throws {
        let source = """
        Lead paragraph.

            indented code line one
            indented code line two

        Trailing paragraph.
        """
        // Editing the trailing paragraph into a ≥4-indent line makes it JOIN
        // the indented block across the blank line.
        let at = offset(of: "Trailing paragraph.", in: source)
        try verify(source, [edit(at, at + 19, "    now part of the code")], "indent-join")
    }

    @Test func editAtDocumentEdges() throws {
        try verify(base, [edit(0, 0, "Prologue line.\n\n")], "prepend")
        let end = base.utf8.count
        try verify(base, [edit(end, end, "\n\nEpilogue line.")], "append-no-trailing-newline")
        try verify(base, [edit(0, 7, "## Replaced Title")], "first-block-replace")
    }

    @Test func htmlBlockEdits() throws {
        let source = """
        Lead paragraph.

        <pre>
        preformatted

        with blank line
        </pre>

        Tail paragraph.
        """
        let at = offset(of: "preformatted", in: source)
        try verify(source, [edit(at, at + 12, "CHANGED")], "pre-interior")
        // Deleting </pre> makes the block swallow downward.
        let close = offset(of: "</pre>", in: source)
        try verify(source, [edit(close, close + 6, "")], "pre-close-delete")
    }

    @Test func refDefIntroductionFallsBack() throws {
        let at = offset(of: "First", in: base)
        let applied = try verify(base, [edit(at, at, "[ref]: https://example.com\n\n")], "ref-def-insert")
        guard case .fullReparse(.referenceDefinitions) = applied else {
            Issue.record("introducing a ref-def must force full reparse, got \(applied)")
            return
        }
    }

    @Test func smallDocumentAndEmptyDocumentFallBack() throws {
        let applied = try verify("just one line", [edit(0, 4, "only")], "small", padTo: 1)
        guard case .fullReparse(.smallDocument) = applied else {
            Issue.record("expected smallDocument fallback")
            return
        }
        var buffer = SourceBuffer(data: Data())
        let summary = try buffer.apply([edit(0, 0, "# New")])
        let outcome = computeEditSplice(
            document: FlatDocument(blocks: []), postEditData: buffer.data,
            summary: summary, mintingIDsFrom: 0
        )
        guard case .fullReparse(.emptyDocument) = outcome else {
            Issue.record("expected emptyDocument fallback")
            return
        }
    }

    @Test func wideReplacementFallsBackAsTooLarge() throws {
        // A POST-edit window over half the document isn't "bounded" in any
        // useful sense; a straight full reparse costs the same and stays
        // simple. (A wide DELETE is different: its post-edit window is small,
        // and the bounded path handles it — see the fuzz corpus.)
        let big = (0..<20).map { "Paragraph number \($0) with plenty of words." }
            .joined(separator: "\n\n")
        let replacement = (0..<18).map { "Replacement paragraph \($0) with plenty of words too." }
            .joined(separator: "\n\n")
        let applied = try verify(
            big, [edit(0, big.utf8.count * 3 / 4, replacement)],
            "three-quarters-replace"
        )
        guard case .fullReparse(.windowTooLarge) = applied else {
            Issue.record("expected windowTooLarge, got \(applied)")
            return
        }
    }

    @Test func multibyteBoundaryEdits() throws {
        let source = "Émigré paragraph with 日本語 and 🚀 rockets in it.\n\nSecond paragraph étude."
        let at = offset(of: "🚀", in: source)
        try verify(source, [edit(at, at + 4, "🛸")], "emoji-replace")
        let accent = offset(of: "étude", in: source)
        try verify(source, [edit(accent, accent + 2, "e")], "accent-replace")
    }

    @Test func crlfDocumentStaysCorrect() throws {
        let source = "# Head\r\n\r\nFirst paragraph.\r\n\r\nSecond paragraph.\r\n"
        let at = offset(of: "First", in: source)
        // CRLF gaps make the blank-line scanner conservative (chains wider);
        // correctness must hold either way.
        try verify(source, [edit(at, at + 5, "Edited")], "crlf")
    }
}
