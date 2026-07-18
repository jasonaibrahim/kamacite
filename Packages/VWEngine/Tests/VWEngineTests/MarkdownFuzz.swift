import Foundation
import Testing
import VWCore
import VWParse
import VWStyle

// Shared support for the editing oracle/property tests: a seeded markdown
// generator, an adversarial edit-batch generator, a naive reference for byte
// splicing, and a FlatDocument comparator that reports the first divergence
// readably (fuzz failures must be diagnosable from the test log).

/// Deterministic LCG so property tests are reproducible. The one copy for the
/// whole test target (top-level `private` types still collide per-module).
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
    mutating func int(in range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
    mutating func chance(_ percent: Int) -> Bool {
        int(in: 0..<100) < percent
    }
    mutating func pick<T>(_ options: [T]) -> T {
        options[int(in: 0..<options.count)]
    }
}

enum MarkdownGen {
    /// A document mixing every construct the engine renders, blank-line
    /// separated so block boundaries are honest. `includeRefDefs` adds link
    /// reference definitions (which gate the bounded-splice path).
    static func document(rng: inout SeededRandom, blockCount: Int, includeRefDefs: Bool = false) -> String {
        var blocks: [String] = []
        for index in 0..<blockCount {
            switch rng.int(in: 0..<(includeRefDefs ? 13 : 12)) {
            case 0:
                blocks.append(String(repeating: "#", count: rng.int(in: 1..<5)) + " Heading \(index) é🚀")
            case 1:
                blocks.append("Setext title \(index)\n" + (rng.chance(50) ? "===" : "---"))
            case 2, 3, 4:
                blocks.append(paragraph(rng: &rng, index: index))
            case 5:
                let marker = rng.chance(70) ? "```" : "~~~"
                let language = rng.pick(["swift", "python", "", "text"])
                var fence = "\(marker)\(language)\nlet value\(index) = \(index)\nprint(value\(index))\n"
                // Occasionally leave the fence unclosed — it legally swallows
                // the rest of the document; the oracle must agree.
                if !rng.chance(4) { fence += marker }
                blocks.append(fence)
            case 6:
                blocks.append("    indented code \(index)\n    second line")
            case 7:
                if rng.chance(50) {
                    blocks.append("- item one \(index)\n- item two *em*\n  - nested item\n- [x] done task")
                } else {
                    blocks.append("1. first \(index)\n2. second\n3. third `code`")
                }
            case 8:
                blocks.append("> quoted line \(index)\nlazy continuation line\n> more quote")
            case 9:
                blocks.append("| alpha | beta |\n| --- | ---: |\n| a\(index) é | 1 |\n| b | 2 |")
            case 10:
                blocks.append(rng.pick([
                    "<div>\nraw <b>html</b> \(index)\n</div>",
                    "<pre>\npreformatted \(index)\n\nwith a blank line\n</pre>",
                    "<!-- a comment\nspanning lines \(index) -->",
                ]))
            case 11:
                blocks.append(rng.pick(["---", "***", "___"]))
            default:
                blocks.append("[ref\(index)]: https://example.com/\(index)\n\nSee [the link][ref\(index)] here.")
            }
        }
        var text = blocks.joined(separator: "\n\n")
        if rng.chance(80) { text += "\n" } // sometimes no trailing newline
        return text
    }

    private static func paragraph(rng: inout SeededRandom, index: Int) -> String {
        let fragments = [
            "plain words \(index)", "*emphasis*", "**strong**", "`inline code`",
            "[link](https://example.com)", "multibyte é 日本 🚀", "trailing",
        ]
        var sentences: [String] = []
        for _ in 0..<rng.int(in: 1..<4) {
            sentences.append((0..<rng.int(in: 2..<5)).map { _ in rng.pick(fragments) }.joined(separator: " ") + ".")
        }
        // Soft breaks inside the paragraph exercise multi-line block spans.
        return sentences.joined(separator: rng.chance(40) ? "\n" : " ")
    }

    /// An adversarial batch against `source`: structure-flavored replacement
    /// tokens at scalar-aligned, non-overlapping spans, with occasional
    /// extreme shapes (edit at 0, append at EOF, whole-document replace).
    static func editBatch(source: Data, rng: inout SeededRandom, maxEdits: Int = 6) -> [SourceEdit] {
        let bytes = [UInt8](source)
        let tokens = [
            "x", "word ", "é", "🚀", " ", "\n", "\n\n", "# ", "## H\n\n", "```\n", "```swift\n",
            "===\n", "---\n", "> ", "- item\n", "| c | d |\n", "**", "`", "*", "[t](https://u.dev)",
            "    indent\n", "<pre>\n", "</pre>\n", "[r]: https://d.ev\n",
        ]
        func replacement() -> String {
            (0..<rng.int(in: 0..<4)).map { _ in rng.pick(tokens) }.joined()
        }

        if rng.chance(2) {
            // Whole-document replace.
            return [SourceEdit(
                span: SourceSpan(startUTF8: 0, endUTF8: bytes.count),
                replacement: "# Fresh\n\n" + replacement() + "\n"
            )]
        }
        if rng.chance(6) {
            // Append at EOF / prepend at 0.
            let offset = rng.chance(50) ? bytes.count : 0
            return [SourceEdit(
                span: SourceSpan(startUTF8: offset, endUTF8: offset),
                replacement: replacement() + "\n"
            )]
        }

        // Random non-overlapping spans: snap offsets to scalar boundaries,
        // sort, use alternate gaps as spans (gaps in between stay untouched).
        // Mostly LOCALIZED clusters (the agent-edit shape — old/new
        // replacements land in one neighborhood; this also concentrates
        // boundary strikes); occasionally document-wide spread, which
        // legitimately exercises the windowTooLarge fallback.
        let localized = rng.chance(75)
        let center = rng.int(in: 0..<bytes.count + 1)
        let radius = rng.int(in: 40..<400)
        var offsets: Set<Int> = []
        for _ in 0..<rng.int(in: 2..<(2 * maxEdits)) {
            var offset = localized
                ? max(0, min(bytes.count, center + rng.int(in: -radius..<radius)))
                : rng.int(in: 0..<bytes.count + 1)
            while offset > 0, offset < bytes.count, bytes[offset] & 0xC0 == 0x80 {
                offset -= 1
            }
            offsets.insert(offset)
        }
        let cuts = offsets.sorted()
        var edits: [SourceEdit] = []
        var i = 0
        while i + 1 < cuts.count {
            let span: SourceSpan
            if rng.chance(25) {
                // Pure insertion at the cut.
                span = SourceSpan(startUTF8: cuts[i], endUTF8: cuts[i])
            } else {
                span = SourceSpan(startUTF8: cuts[i], endUTF8: cuts[i + 1])
            }
            edits.append(SourceEdit(span: span, replacement: replacement()))
            i += 2
        }
        return edits
    }
}

/// Naive reference: splice through a byte array, descending offsets.
func referenceApply(_ source: Data, _ edits: [SourceEdit]) -> Data {
    var bytes = [UInt8](source)
    let sorted = edits.enumerated().sorted {
        ($0.element.span.startUTF8, $0.element.span.endUTF8, $0.offset)
            < ($1.element.span.startUTF8, $1.element.span.endUTF8, $1.offset)
    }
    for entry in sorted.reversed() {
        bytes.replaceSubrange(
            entry.element.span.startUTF8..<entry.element.span.endUTF8,
            with: [UInt8](entry.element.replacement)
        )
    }
    return Data(bytes)
}

/// Two spans agree when byte-identical OR both empty: an empty span slices
/// to "" wherever it points, so its position carries no information — and
/// the engine's suffix shift deliberately leaves empties in place (the
/// parser's rangeless sentinels are absolute; swift-markdown additionally
/// reports zero-length ranges at inconsistent positions).
private func spansAgree(_ a: SourceSpan?, _ b: SourceSpan?) -> Bool {
    if a == b { return true }
    if let a, let b { return a.isEmpty && b.isEmpty }
    return false
}

private func runsAgree(_ a: StyledRun, _ b: StyledRun) -> Bool {
    a.text == b.text && a.traits == b.traits && a.color == b.color
        && a.link == b.link && spansAgree(a.span, b.span)
}

private func runArraysAgree(_ a: [StyledRun], _ b: [StyledRun]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy(runsAgree)
}

private func tableRowsAgree(_ a: TableRowInfo?, _ b: TableRowInfo?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (let a?, let b?):
        return a.tableIndex == b.tableIndex && a.rowIndex == b.rowIndex
            && a.isHeader == b.isHeader && a.isLastRow == b.isLastRow
            && a.cells.count == b.cells.count
            && zip(a.cells, b.cells).allSatisfy(runArraysAgree)
    default: return false
    }
}

/// Field-by-field FlatDocument comparison, BlockID excluded (re-minted per
/// parse) and `diagram` excluded (session-swapped, never from the flattener).
/// Records ONE readable issue at the first divergence and stops.
@discardableResult
func expectFlatDocumentsMatch(
    _ actual: FlatDocument, _ oracle: FlatDocument,
    _ context: @autoclosure () -> String = ""
) -> Bool {
    func fail(_ message: String) -> Bool {
        Issue.record("\(message)\(context().isEmpty ? "" : " [\(context())]")")
        return false
    }
    guard actual.blocks.count == oracle.blocks.count else {
        return fail("block count \(actual.blocks.count) != oracle \(oracle.blocks.count)")
    }
    guard actual.tables == oracle.tables else {
        return fail("tables \(actual.tables) != oracle \(oracle.tables)")
    }
    for index in actual.blocks.indices {
        let a = actual.blocks[index]
        let o = oracle.blocks[index]
        func failBlock(_ field: String, _ av: Any, _ ov: Any) -> Bool {
            fail("block \(index) \(field): \(av) != oracle \(ov) (kind \(a.kind)/\(o.kind))")
        }
        if !spansAgree(a.span, o.span) { return failBlock("span", a.span, o.span) }
        if a.kind != o.kind { return failBlock("kind", a.kind, o.kind) }
        if a.quoteDepth != o.quoteDepth { return failBlock("quoteDepth", a.quoteDepth, o.quoteDepth) }
        if a.listDepth != o.listDepth { return failBlock("listDepth", a.listDepth, o.listDepth) }
        if a.marker != o.marker {
            return failBlock("marker", String(describing: a.marker), String(describing: o.marker))
        }
        if a.codeLanguage != o.codeLanguage {
            return failBlock("codeLanguage", String(describing: a.codeLanguage), String(describing: o.codeLanguage))
        }
        if !tableRowsAgree(a.tableRow, o.tableRow) {
            return failBlock("tableRow", String(describing: a.tableRow), String(describing: o.tableRow))
        }
        if a.isContinuation != o.isContinuation {
            return failBlock("isContinuation", a.isContinuation, o.isContinuation)
        }
        if a.continues != o.continues { return failBlock("continues", a.continues, o.continues) }
        if !runArraysAgree(a.runs, o.runs) {
            let firstDiff = zip(a.runs, o.runs).enumerated().first { !runsAgree($1.0, $1.1) }
            if let (runIndex, (actualRun, oracleRun)) = firstDiff {
                return failBlock("runs[\(runIndex)]", actualRun, oracleRun)
            }
            return failBlock("runs count", a.runs.count, o.runs.count)
        }
    }
    return true
}
