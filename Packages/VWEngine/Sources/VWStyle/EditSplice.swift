import Foundation
import VWCore
import VWParse

// The edit splice: the value that carries a bounded reparse into the live
// document. computeEditSplice (the boundary picker) decides HOW MUCH to
// reparse; applyEditSplice is pure index/span arithmetic that swaps the
// affected block range in and shifts everything after it. Splitting the two
// keeps the arithmetic fuzzable without a parser in the loop.

/// A bounded re-derivation of `blockRange`: the blocks (and tables) that
/// replace it, with every span already in absolute POST-edit coordinates and
/// every embedded table index already final. The suffix (blocks at and after
/// `blockRange.upperBound`) still needs shifting — that is applyEditSplice's
/// job, not the producer's.
public struct ContentEditSplice: Sendable {
    /// Pre-edit flat indices being replaced.
    public var blockRange: Range<Int>
    /// Pre-edit indices into `FlatDocument.tables` owned by `blockRange`.
    public var tableRange: Range<Int>
    /// Spans absolute post-edit; `tableRow.tableIndex` final.
    public var newBlocks: [FlatBlock]
    /// `firstRowFlatIndex` absolute in the final (post-splice) index space.
    public var newTables: [FlatTable]
    public var byteDelta: Int
    /// Post-edit byte range that was reparsed (perf marks, tests).
    public var reparsedRange: Range<Int>

    public init(
        blockRange: Range<Int>, tableRange: Range<Int>,
        newBlocks: [FlatBlock], newTables: [FlatTable],
        byteDelta: Int, reparsedRange: Range<Int>
    ) {
        self.blockRange = blockRange
        self.tableRange = tableRange
        self.newBlocks = newBlocks
        self.newTables = newTables
        self.byteDelta = byteDelta
        self.reparsedRange = reparsedRange
    }

    public var blockDelta: Int { newBlocks.count - blockRange.count }
    public var tableDelta: Int { newTables.count - tableRange.count }
}

/// Splice `splice` into `document`: shift every suffix block's spans by
/// `byteDelta` (block, runs, and table-cell runs — they all anchor copy and
/// selection), suffix `tableRow.tableIndex` by the table-count delta, suffix
/// `FlatTable.firstRowFlatIndex` by the block-count delta, then replace the
/// ranges. O(suffix); memory-bandwidth-bound.
public func applyEditSplice(_ splice: ContentEditSplice, to document: inout FlatDocument) {
    let blockDelta = splice.blockDelta
    let tableDelta = splice.tableDelta

    if splice.byteDelta != 0 || tableDelta != 0 {
        for index in splice.blockRange.upperBound..<document.blocks.count {
            shiftBlock(&document.blocks[index], byteDelta: splice.byteDelta, tableDelta: tableDelta)
        }
    }
    if blockDelta != 0 {
        for index in splice.tableRange.upperBound..<document.tables.count {
            document.tables[index].firstRowFlatIndex += blockDelta
        }
    }
    document.blocks.replaceSubrange(splice.blockRange, with: splice.newBlocks)
    document.tables.replaceSubrange(splice.tableRange, with: splice.newTables)
}

private func shiftBlock(_ block: inout FlatBlock, byteDelta: Int, tableDelta: Int) {
    block.span = block.span.offset(by: byteDelta)
    if byteDelta != 0 {
        for index in block.runs.indices {
            block.runs[index].span = block.runs[index].span?.offset(by: byteDelta)
        }
    }
    if var row = block.tableRow {
        row.tableIndex += tableDelta
        if byteDelta != 0 {
            for cell in row.cells.indices {
                for run in row.cells[cell].indices {
                    row.cells[cell][run].span = row.cells[cell][run].span?.offset(by: byteDelta)
                }
            }
        }
        block.tableRow = row
    }
}

extension SourceSpan {
    /// Empty spans don't move: they are either the parser's rangeless (0,0)
    /// sentinel (absolute by definition) or degenerate — both slice to ""
    /// wherever they point, and a fresh parse would reproduce them unshifted.
    func offset(by delta: Int) -> SourceSpan {
        guard !isEmpty else { return self }
        return SourceSpan(startUTF8: startUTF8 + delta, endUTF8: endUTF8 + delta)
    }
}

// MARK: - Bounded reparse

/// Why an edit fell back to a whole-document reparse. Carried on the outcome
/// so tests can assert the bounded path is actually exercised (a fallback
/// that always fires would be silently correct and silently slow).
public enum EditFallbackReason: String, Sendable {
    case emptyDocument
    case smallDocument
    case windowTooLarge
    case referenceDefinitions
    case edgeAmbiguity
}

public enum EditSpliceOutcome: Sendable {
    case splice(ContentEditSplice)
    case fullReparse(EditFallbackReason)
}

/// Blocks below this take the full-reparse path outright: the bounded
/// machinery exists to make LARGE-document edits fast, and a small parse is
/// cheaper than being clever.
let boundedReparseMinBlocks = 16

/// Bound the reparse for one applied batch: decide the smallest block window
/// whose reparse provably agrees with a whole-document parse, parse just
/// those bytes (span-rebased), and return the splice. Falls back whenever
/// markdown's context sensitivity can't be locally contained.
///
/// The window construction invariants (each is load-bearing):
/// - Every block whose span intersects the changed range is in the window,
///   PLUS one neighbor on each side — edits at a block's edge can merge it
///   with its neighbor (deleting the blank line between them), and an
///   insertion into a gap can attach to either side.
/// - Chained neighbors join the window: mega-block fragments, same-table
///   rows, list content (ordered renumbering is document-order-dependent
///   within the list), adjacent quote content, and any gap with no blank
///   line (which subsumes setext underlines and lazy continuations).
/// - Window byte edges sit on blank-line boundaries by construction: gaps
///   the chain expansion stopped at contain a blank line, and (ref-defs
///   being gated) gaps hold nothing but blank lines.
/// - A fence-parity scan widens to EOF when the chunk would end inside an
///   open fence — an edit that deletes a closer legally swallows the rest
///   of the document, and the cost should be honest.
/// - Post-parse edge verification catches the constructs that legally leak
///   across blank lines (indented code, list absorption, HTML blocks) and
///   widens; after `maxWidenRetries` it stops arguing and full-reparses.
public func computeEditSplice(
    document: FlatDocument,
    postEditData: Data,
    summary: SourceEditSummary,
    mintingIDsFrom idBase: UInt64
) -> EditSpliceOutcome {
    guard !document.blocks.isEmpty else { return .fullReparse(.emptyDocument) }
    guard document.blocks.count >= boundedReparseMinBlocks else { return .fullReparse(.smallDocument) }

    // Borrow, never copy: an upfront [UInt8](postEditData) would be O(document)
    // per edit — the exact cost the bounded path exists to avoid. Every scan
    // below is O(window); only the chunk itself gets materialized (for cmark).
    return postEditData.withUnsafeBytes { raw -> EditSpliceOutcome in
        computeEditSpliceScanning(
            document: document, post: raw.bindMemory(to: UInt8.self),
            postEditData: postEditData, summary: summary, mintingIDsFrom: idBase
        )
    }
}

private func computeEditSpliceScanning(
    document: FlatDocument,
    post: UnsafeBufferPointer<UInt8>,
    postEditData: Data,
    summary: SourceEditSummary,
    mintingIDsFrom idBase: UInt64
) -> EditSpliceOutcome {
    let delta = summary.byteDelta
    let changedPre = summary.changedPreEdit
    let preCount = post.count - delta

    // Pre-edit byte access through the post buffer: bytes below the changed
    // range are identical, bytes at/after its end sit `delta` later. Reading
    // INSIDE the changed range has no pre-space answer — callers stay out.
    func preByte(_ p: Int) -> UInt8? {
        if p < changedPre.startUTF8 { return p >= 0 ? post[p] : nil }
        if p >= changedPre.endUTF8 { return p + delta < post.count ? post[p + delta] : nil }
        return nil
    }

    let blocks = document.blocks

    // MARK: Window seeding

    // Blocks with EMPTY spans (the parser's rangeless sentinel) have no byte
    // anchor: they must not seed the window (a mid-document sentinel would
    // match "starts before X" for every X) — the chain rule below glues them
    // to their neighbors instead, so the chunk regenerates them.

    // First block whose span END is past the change start …
    var lo = blocks.firstIndex {
        !$0.span.isEmpty && $0.span.endUTF8 > changedPre.startUTF8
    } ?? blocks.count
    // … last block whose span START is before the change end.
    var hi = (blocks.lastIndex {
        !$0.span.isEmpty && $0.span.startUTF8 < changedPre.endUTF8
    }.map { $0 + 1 }) ?? 0
    if lo >= hi {
        // Insertion into a gap (or at either end): an empty window positioned
        // between the neighbors.
        let position = lo
        lo = position
        hi = position
    }
    // Always take one neighbor each side (edge merges, gap attachment).
    lo = max(0, lo - 1)
    hi = min(blocks.count, hi + 1)

    // MARK: Chain expansion

    func blankLineInGap(_ gapStart: Int, _ gapEnd: Int) -> Bool {
        guard gapStart < gapEnd else { return false }
        var p = gapStart
        while p < gapEnd {
            guard let byte = preByte(p) else { return false } // touches the edit: stay chained
            if byte == 0x0A {
                var q = p + 1
                while q < gapEnd, let b = preByte(q), b == 0x20 || b == 0x09 || b == 0x0D {
                    q += 1
                }
                if q < gapEnd, preByte(q) == 0x0A { return true }
                // A gap ending in newline + trailing spaces right before the
                // next block's line means that partial line IS blank up to
                // the block's own indent — but the block starts on it, so it
                // is not a separating blank line. Keep scanning.
                p = q
            } else {
                p += 1
            }
        }
        return false
    }

    func chained(_ a: Int, _ b: Int) -> Bool {
        let first = blocks[a]
        let second = blocks[b]
        // A rangeless block travels with its neighbors: it has no bytes of
        // its own to bound a window edge on.
        if first.span.isEmpty || second.span.isEmpty { return true }
        if first.continues || second.isContinuation { return true }
        if let ta = first.tableRow?.tableIndex, ta == second.tableRow?.tableIndex { return true }
        if first.listDepth > 0 || second.listDepth > 0
            || first.kind == .listItem || second.kind == .listItem { return true }
        if first.quoteDepth > 0, second.quoteDepth > 0 { return true }
        return !blankLineInGap(first.span.endUTF8, second.span.startUTF8)
    }

    // MARK: Widen-retry loop

    let maxWidenRetries = 3
    var retries = 0

    while true {
        // (Re)run chain expansion — widening moved an edge onto blocks whose
        // own neighbors may be chained; expansion is idempotent.
        while lo > 0, chained(lo - 1, lo) { lo -= 1 }
        while hi < blocks.count, chained(hi - 1, hi) { hi += 1 }
        // Byte edges (pre space → post space; both mappings are provably on
        // the clean side of the changed range, see preByte).
        let loPost: Int
        if lo == 0 {
            loPost = 0
        } else {
            let seed = min(blocks[lo].span.startUTF8, changedPre.startUTF8)
            var p = seed
            while p > 0, preByte(p - 1) != 0x0A { p -= 1 }
            loPost = p // below changedPre.start ⇒ identity mapping
        }
        let hiPost: Int
        if hi == blocks.count {
            hiPost = post.count
        } else {
            var p = max(blocks[hi - 1].span.endUTF8, changedPre.endUTF8) + delta
            while p < post.count, post[p] != 0x0A { p += 1 }
            hiPost = min(post.count, p + 1)
        }

        if (hiPost - loPost) * 2 > post.count { return .fullReparse(.windowTooLarge) }

        // Open fence at chunk end swallows the suffix for real: be honest.
        if hi < blocks.count, chunkEndsInsideOpenFence(post, from: loPost, to: hiPost) {
            hi = blocks.count
            retries += 1
            if retries > maxWidenRetries { return .fullReparse(.edgeAmbiguity) }
            continue
        }

        // A definition inside the (post-edit) chunk changes links anywhere in
        // the document — no splice can express that.
        if containsLinkReferenceDefinitions(postEditData, in: loPost..<hiPost) {
            return .fullReparse(.referenceDefinitions)
        }

        let chunk = String(decoding: post[loPost..<hiPost], as: UTF8.self)
        let flat = flatten(parseMarkdown(chunk, spanOffset: loPost, mintingIDsFrom: idBase))

        // MARK: Edge verification (constructs that legally cross blank lines)

        func firstNonBlankLineIndent(after offset: Int) -> Int? {
            var p = offset
            while p < post.count {
                var q = p
                var indent = 0
                while q < post.count, post[q] == 0x20 || post[q] == 0x09 {
                    indent += post[q] == 0x09 ? 4 : 1
                    q += 1
                }
                if q >= post.count || post[q] == 0x0A || post[q] == 0x0D {
                    // Blank line; advance past it.
                    while p < post.count, post[p] != 0x0A { p += 1 }
                    p += 1
                    continue
                }
                return indent
            }
            return nil
        }

        var widen = false
        if hi < blocks.count, let last = flat.blocks.last {
            let tailIndent = firstNonBlankLineIndent(after: hiPost)
            let lastIsIndentedCode = (last.kind == .codeBlock) && last.codeLanguage == nil
                && !chunkByteIsFenceMarker(post, span: last.span)
            if lastIsIndentedCode, let indent = tailIndent, indent >= 4 {
                hi += 1
                widen = true
            } else if (last.kind == .listItem || last.listDepth > 0),
                      let indent = tailIndent, indent >= 1 {
                // Indented lines after a blank can rejoin the list.
                hi += 1
                widen = true
            } else if isHTMLParagraph(last), last.span.endUTF8 >= hiPost - 1 {
                // An HTML block reaching the chunk edge may be unterminated
                // (<pre>, <!--) and swallow past it.
                hi += 1
                widen = true
            }
        }
        if !widen, lo > 0, let first = flat.blocks.first {
            // A ≥4-indent first line can merge into a preceding indented
            // code block across the blank boundary.
            let prev = blocks[lo - 1]
            let prevIsIndentedCode = (prev.kind == .codeBlock) && prev.codeLanguage == nil
            let firstIndented = (first.kind == .codeBlock) && first.codeLanguage == nil
                && !chunkByteIsFenceMarker(post, span: first.span)
            if prevIsIndentedCode, firstIndented {
                lo -= 1
                widen = true
            }
        }
        if widen {
            retries += 1
            if retries > maxWidenRetries { return .fullReparse(.edgeAmbiguity) }
            continue
        }

        // MARK: Assemble

        // Tables owned by the window: contiguous by construction (chaining
        // never splits a table).
        let tableLo = document.tables.firstIndex { $0.firstRowFlatIndex >= lo }
            ?? document.tables.count
        let tableHi = document.tables.firstIndex { $0.firstRowFlatIndex >= hi }
            ?? document.tables.count
        let tableRange = tableLo..<max(tableLo, tableHi)

        var newBlocks = flat.blocks
        var newTables = flat.tables
        for index in newBlocks.indices where newBlocks[index].tableRow != nil {
            newBlocks[index].tableRow!.tableIndex += tableRange.lowerBound
        }
        for index in newTables.indices {
            newTables[index].firstRowFlatIndex += lo
        }

        return .splice(ContentEditSplice(
            blockRange: lo..<hi,
            tableRange: tableRange,
            newBlocks: newBlocks,
            newTables: newTables,
            byteDelta: delta,
            reparsedRange: loPost..<hiPost
        ))
    }
}

/// Fence parity over an arbitrary chunk, with the CommonMark rules that
/// matter for not being fooled: a CLOSING fence is marker-only (spaces
/// aside) and at least as long as the opener — "```---" inside an open ```
/// fence is content, not a closer — and a backtick OPENER's info string may
/// not contain a backtick. Ends-open means the chunk boundary is unsafe.
private func chunkEndsInsideOpenFence(_ post: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Bool {
    var inFence = false
    var fenceMarker: UInt8 = 0
    var fenceLength = 0
    var lineStart = from
    while lineStart < to {
        var lineEnd = lineStart
        while lineEnd < to, post[lineEnd] != 0x0A { lineEnd += 1 }
        var i = lineStart
        var leadingSpaces = 0
        while i < lineEnd, post[i] == 0x20, leadingSpaces < 4 {
            i += 1
            leadingSpaces += 1
        }
        if leadingSpaces < 4, i < lineEnd {
            let marker = post[i]
            if marker == 0x60 || marker == 0x7E { // ` or ~
                var run = 0
                while i + run < lineEnd, post[i + run] == marker { run += 1 }
                if run >= 3 {
                    var rest = i + run
                    var restIsBlank = true
                    var restHasBacktick = false
                    while rest < lineEnd {
                        let byte = post[rest]
                        if byte != 0x20, byte != 0x09, byte != 0x0D { restIsBlank = false }
                        if byte == 0x60 { restHasBacktick = true }
                        rest += 1
                    }
                    if inFence {
                        if marker == fenceMarker, run >= fenceLength, restIsBlank {
                            inFence = false
                        }
                    } else if marker == 0x7E || !restHasBacktick {
                        inFence = true
                        fenceMarker = marker
                        fenceLength = run
                    }
                }
            }
        }
        lineStart = lineEnd + 1
    }
    return inFence
}

private func chunkByteIsFenceMarker(_ post: UnsafeBufferPointer<UInt8>, span: SourceSpan) -> Bool {
    guard span.startUTF8 < post.count else { return false }
    let byte = post[span.startUTF8]
    return byte == 0x60 || byte == 0x7E
}

private func isHTMLParagraph(_ block: FlatBlock) -> Bool {
    // The flattener renders html blocks as mono secondary paragraphs; the
    // structural signal that survives is a run starting with '<'.
    block.kind == .paragraph && (block.runs.first?.text.hasPrefix("<") ?? false)
}

/// Cheap scan for link reference definitions (`[label]: destination`), which
/// cmark resolves document-globally — the one construct a bounded reparse
/// can never contain. Conservative by design: a line-leading `[` with `]:`
/// on the line flags, and a line-leading `[` with NO `]` at all flags too
/// (multi-line labels are legal). Container prefixes (quotes, list markers)
/// are skipped first — definitions inside them are still global. False
/// positives only cost a full reparse.
public func containsLinkReferenceDefinitions(_ data: Data, in range: Range<Int>? = nil) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        let bytes = raw.bindMemory(to: UInt8.self)
        let start = range?.lowerBound ?? 0
        let end = min(range?.upperBound ?? bytes.count, bytes.count)
        var lineStart = start
        while lineStart < end {
            var lineEnd = lineStart
            while lineEnd < end, bytes[lineEnd] != 0x0A { lineEnd += 1 }

            // Skip container prefixes: spaces, tabs, '>', list markers.
            var i = lineStart
            scan: while i < lineEnd {
                switch bytes[i] {
                case 0x20, 0x09, 0x3E, 0x2D, 0x2B, 0x2A, 0x2E, 0x29, 0x30...0x39:
                    i += 1
                default:
                    break scan
                }
            }
            if i < lineEnd, bytes[i] == 0x5B { // '['
                var sawClose = false
                var j = i + 1
                while j < lineEnd {
                    if bytes[j] == 0x5D { // ']'
                        sawClose = true
                        if j + 1 < lineEnd, bytes[j + 1] == 0x3A { return true } // "]:"
                    }
                    j += 1
                }
                if !sawClose { return true } // possible multi-line label
            }
            lineStart = lineEnd + 1
        }
        return false
    }
}
