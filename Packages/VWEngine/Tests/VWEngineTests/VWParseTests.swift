import Foundation
import Testing
import VWCore
@testable import VWParse

private func slice(_ source: String, _ span: SourceSpan) -> String {
    let bytes = Array(source.utf8)
    guard span.startUTF8 <= bytes.count else { return "" }
    let end = min(span.endUTF8, bytes.count)
    return String(decoding: bytes[span.startUTF8..<end], as: UTF8.self)
}

@Suite struct LineTableTests {
    @Test func asciiOffsets() {
        let table = LineTable(text: "abc\ndef\n")
        #expect(table.utf8Offset(line: 1, column: 1) == 0)
        #expect(table.utf8Offset(line: 1, column: 4) == 3)
        #expect(table.utf8Offset(line: 2, column: 1) == 4)
        #expect(table.utf8Offset(line: 2, column: 3) == 6)
    }

    @Test func multibyteColumnsAreBytes() {
        // é = 2 bytes, 🚀 = 4 bytes.
        let table = LineTable(text: "é🚀\nx")
        #expect(table.utf8Offset(line: 2, column: 1) == 7)
    }

    @Test func outOfRangeClamps() {
        let table = LineTable(text: "ab")
        #expect(table.utf8Offset(line: 9, column: 9) == 2)
        #expect(table.utf8Offset(line: 0, column: 0) == 0)
    }
}

@Suite struct ParserTests {
    @Test func headingAndParagraph() {
        let source = "# Hello\n\nWorld *waves* back."
        let tree = parseMarkdown(source)
        #expect(tree.blocks.count == 2)

        guard case .heading(let level, let inlines) = tree.blocks[0].kind else {
            Issue.record("expected heading, got \(tree.blocks[0].kind)")
            return
        }
        #expect(level == 1)
        #expect(inlines.map(\.plainText).joined() == "Hello")
        #expect(slice(source, tree.blocks[0].span) == "# Hello")

        guard case .paragraph(let paragraphInlines) = tree.blocks[1].kind else {
            Issue.record("expected paragraph")
            return
        }
        #expect(paragraphInlines.contains { if case .emphasis = $0.kind { true } else { false } })
        #expect(slice(source, tree.blocks[1].span) == "World *waves* back.")
    }

    @Test func inlineStructure() {
        let tree = parseMarkdown("a **b** `c` ~~d~~ [e](https://x.example)")
        guard case .paragraph(let inlines) = tree.blocks[0].kind else {
            Issue.record("expected paragraph")
            return
        }
        var kinds: [String] = []
        for node in inlines {
            switch node.kind {
            case .text: kinds.append("text")
            case .strong: kinds.append("strong")
            case .code: kinds.append("code")
            case .strikethrough: kinds.append("strike")
            case .link(let destination, _):
                kinds.append("link")
                #expect(destination == "https://x.example")
            default: break
            }
        }
        #expect(kinds.contains("strong"))
        #expect(kinds.contains("code"))
        #expect(kinds.contains("strike"))
        #expect(kinds.contains("link"))
    }

    @Test func codeBlockKeepsLanguageAndBody() {
        let source = "```swift\nlet x = 1\n```"
        let tree = parseMarkdown(source)
        guard case .codeBlock(let language, let code, let contentSpan) = tree.blocks[0].kind else {
            Issue.record("expected code block")
            return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1\n")
        // Content span is byte-verified: slicing the source by it MUST yield
        // the code exactly.
        #expect(contentSpan != nil)
        if let contentSpan {
            #expect(slice(source, contentSpan) == code)
        }
    }

    @Test func fencedCodeContentSpanSurvivesPrecedingContent() {
        let source = "# Héading with é\n\nsome *prose* first\n\n```python\nx = \"é\"\ny = 2\n```\n\ntail"
        let tree = parseMarkdown(source)
        guard let block = tree.blocks.first(where: {
            if case .codeBlock = $0.kind { return true } else { return false }
        }), case .codeBlock(_, let code, let contentSpan) = block.kind else {
            Issue.record("expected code block")
            return
        }
        #expect(contentSpan != nil)
        if let contentSpan {
            #expect(slice(source, contentSpan) == code)
        }
    }

    @Test func quotedFenceHasNoContentSpan() {
        // Inside a blockquote every line carries a "> " prefix — the content
        // is NOT a contiguous source slice, and pretending otherwise would
        // corrupt source copies.
        let tree = parseMarkdown("> ```swift\n> let x = 1\n> let y = 2\n> ```")
        guard case .blockquote(let children) = tree.blocks[0].kind,
              case .codeBlock(_, _, let contentSpan) = children[0].kind else {
            Issue.record("expected quoted code block")
            return
        }
        #expect(contentSpan == nil)
    }

    @Test func indentedMultilineCodeHasNoContentSpan() {
        let tree = parseMarkdown("para\n\n    line one\n    line two\n")
        guard let block = tree.blocks.first(where: {
            if case .codeBlock = $0.kind { return true } else { return false }
        }), case .codeBlock(_, _, let contentSpan) = block.kind else {
            Issue.record("expected indented code block")
            return
        }
        #expect(contentSpan == nil)
    }

    @Test func taskListCheckboxes() {
        let tree = parseMarkdown("- [x] done\n- [ ] todo\n- plain")
        guard case .list(let ordered, _, let items) = tree.blocks[0].kind else {
            Issue.record("expected list")
            return
        }
        #expect(!ordered)
        #expect(items.count == 3)
        #expect(items[0].checkbox == true)
        #expect(items[1].checkbox == false)
        #expect(items[2].checkbox == nil)
    }

    @Test func orderedListStart() {
        let tree = parseMarkdown("3. three\n4. four")
        guard case .list(let ordered, let start, let items) = tree.blocks[0].kind else {
            Issue.record("expected list")
            return
        }
        #expect(ordered)
        #expect(start == 3)
        #expect(items.count == 2)
    }

    @Test func tableStructure() {
        let tree = parseMarkdown("| a | b |\n| :-- | --: |\n| 1 | 2 |")
        guard case .table(let alignments, let head, let body) = tree.blocks[0].kind else {
            Issue.record("expected table")
            return
        }
        #expect(alignments == [.left, .right])
        #expect(head.count == 2)
        #expect(body.count == 1)
        #expect(body[0].map { $0.map(\.plainText).joined() } == ["1", "2"])
    }

    @Test func blockquoteNesting() {
        let tree = parseMarkdown("> outer\n>\n> > inner")
        guard case .blockquote(let children) = tree.blocks[0].kind else {
            Issue.record("expected blockquote")
            return
        }
        #expect(children.count == 2)
        guard case .blockquote = children[1].kind else {
            Issue.record("expected nested blockquote")
            return
        }
    }

    @Test func blockIDsAreUniqueAndMonotonic() {
        let tree = parseMarkdown("# a\n\nb\n\n- c\n- d")
        var seen: Set<UInt64> = []
        func walk(_ blocks: [ContentBlock]) {
            for block in blocks {
                #expect(!seen.contains(block.id.rawValue))
                seen.insert(block.id.rawValue)
                switch block.kind {
                case .blockquote(let children): walk(children)
                case .list(_, _, let items): items.forEach { walk($0.children) }
                default: break
                }
            }
        }
        walk(tree.blocks)
        #expect(seen.count >= 4)
    }

    @Test func lossyUTF8DoesNotCrash() {
        var data = Data("# ok\n".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x0A])
        let tree = parseMarkdown(data: data)
        #expect(!tree.blocks.isEmpty)
    }
}
