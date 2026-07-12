import Testing
import VWParse
@testable import VWStyle

@Suite struct FlattenTests {
    private func flat(_ markdown: String) -> FlatDocument {
        flatten(parseMarkdown(markdown))
    }

    @Test func inlineTraits() {
        let doc = flat("plain **bold** *italic* ***both*** `mono` ~~gone~~")
        let runs = doc.blocks[0].runs
        #expect(runs.first { $0.text == "bold" }?.traits == .bold)
        #expect(runs.first { $0.text == "italic" }?.traits == .italic)
        #expect(runs.first { $0.text == "both" }?.traits == [.bold, .italic])
        let mono = runs.first { $0.text == "mono" }
        #expect(mono?.traits == .mono)
        #expect(mono?.color == .codeText)
        #expect(runs.first { $0.text == "gone" }?.traits == .strikethrough)
    }

    @Test func linksGetAccentColor() {
        let doc = flat("[click](https://x.example)")
        #expect(doc.blocks[0].runs.first { $0.text == "click" }?.color == .accent)
    }

    @Test func softBreakBecomesSpace() {
        let doc = flat("one\ntwo")
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].runs.map(\.text).joined() == "one two")
    }

    @Test func listMarkersAndDepth() {
        let doc = flat("- alpha\n- beta\n  - nested\n\n1. first")
        let items = doc.blocks.filter { $0.kind == .listItem }
        #expect(items.count == 4)
        #expect(items[0].marker == "•")
        #expect(items[0].listDepth == 0)
        // Text indents one unit past the marker column (hanging indent).
        #expect(items[0].indentLevel == 1)
        let nested = items.first { $0.runs.map(\.text).joined().contains("nested") }
        #expect(nested?.listDepth == 1)
        #expect(nested?.marker == "◦")
        #expect(nested?.indentLevel == 2)
        let ordered = items.first { $0.runs.map(\.text).joined().contains("first") }
        #expect(ordered?.marker == "1.")
    }

    @Test func checkboxMarkers() {
        let doc = flat("- [x] done\n- [ ] todo")
        #expect(doc.blocks[0].marker == "☑")
        #expect(doc.blocks[1].marker == "☐")
        // The marker is NOT part of the copyable text.
        #expect(doc.blocks[0].runs.map(\.text).joined() == "done")
    }

    @Test func linksCarryDestination() {
        let doc = flat("see [the docs](https://example.org/docs) here")
        let linkRun = doc.blocks[0].runs.first { $0.text == "the docs" }
        #expect(linkRun?.link == "https://example.org/docs")
        #expect(linkRun?.color == .accent)
        #expect(doc.blocks[0].runs.first { $0.text.contains("see") }?.link == nil)
    }

    @Test func codeBlockCarriesLanguage() {
        let doc = flat("```swift\nlet x = 1\n```")
        #expect(doc.blocks[0].codeLanguage == "swift")
    }

    @Test func quoteReadsSecondaryWithDepth() {
        let doc = flat("> quoted text")
        #expect(doc.blocks[0].quoteDepth == 1)
        #expect(doc.blocks[0].runs[0].color == .secondaryText)
    }

    @Test func codeBlockTrimsTrailingNewline() {
        let doc = flat("```\nline1\nline2\n```")
        #expect(doc.blocks[0].kind == .codeBlock)
        #expect(doc.blocks[0].runs[0].text == "line1\nline2")
        #expect(doc.blocks[0].baseFontClass == .code)
    }

    @Test func tableDegradesToMonoRows() {
        let doc = flat("| a | b |\n| --- | --- |\n| 1 | 2 |")
        let rows = doc.blocks.filter { $0.kind == .tableRow }
        #expect(rows.count == 2)
        #expect(rows[0].runs[0].traits.contains(.bold))
        #expect(rows[1].runs[0].text == "1   2")
    }

    @Test func ruleSurvivesWithNoRuns() {
        let doc = flat("above\n\n---\n\nbelow")
        #expect(doc.blocks.contains { $0.kind == .rule })
    }

    @Test func headingSixIsSecondary() {
        let doc = flat("###### tiny")
        #expect(doc.blocks[0].kind == .heading(6))
        #expect(doc.blocks[0].runs[0].color == .secondaryText)
    }
}
