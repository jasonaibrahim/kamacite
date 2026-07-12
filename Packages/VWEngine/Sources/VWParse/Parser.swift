import Foundation
import Markdown
import VWCore

// swift-markdown (cmark-gfm) → ContentTree. The Markup AST is a class graph
// with parent back-references and no Sendable conformance; it is converted and
// released before this function returns.

public func parseMarkdown(data: Data) -> ContentTree {
    // Lossy decode: invalid UTF-8 becomes U+FFFD. Spans stay consistent because
    // the line table is built over the same decoded string cmark parses.
    parseMarkdown(String(decoding: data, as: UTF8.self))
}

public func parseMarkdown(_ text: String) -> ContentTree {
    let document = Document(parsing: text)
    var converter = Converter(lineTable: LineTable(text: text))
    let blocks = document.children.compactMap { converter.block($0) }
    return ContentTree(blocks: blocks, sourceUTF8Count: converter.lineTable.utf8Count)
}

private struct Converter {
    let lineTable: LineTable
    private var nextID: UInt64 = 0

    init(lineTable: LineTable) {
        self.lineTable = lineTable
    }

    private mutating func mintID() -> BlockID {
        defer { nextID += 1 }
        return BlockID(rawValue: nextID)
    }

    private func span(_ markup: Markup) -> SourceSpan {
        guard let range = markup.range else {
            return SourceSpan(startUTF8: 0, endUTF8: 0)
        }
        let start = lineTable.utf8Offset(line: range.lowerBound.line, column: range.lowerBound.column)
        let end = lineTable.utf8Offset(line: range.upperBound.line, column: range.upperBound.column)
        return SourceSpan(startUTF8: min(start, end), endUTF8: max(start, end))
    }

    // MARK: - Blocks

    mutating func block(_ markup: Markup) -> ContentBlock? {
        let id = mintID()
        let span = span(markup)

        switch markup {
        case let heading as Heading:
            return ContentBlock(id: id, span: span, kind: .heading(
                level: heading.level, inlines: inlines(of: heading)
            ))
        case let paragraph as Paragraph:
            return ContentBlock(id: id, span: span, kind: .paragraph(inlines: inlines(of: paragraph)))
        case let code as CodeBlock:
            return ContentBlock(id: id, span: span, kind: .codeBlock(
                language: code.language, code: code.code
            ))
        case let quote as BlockQuote:
            return ContentBlock(id: id, span: span, kind: .blockquote(
                children: quote.children.compactMap { block($0) }
            ))
        case let list as UnorderedList:
            return ContentBlock(id: id, span: span, kind: .list(
                ordered: false, start: 1, items: list.children.compactMap { item($0) }
            ))
        case let list as OrderedList:
            return ContentBlock(id: id, span: span, kind: .list(
                ordered: true, start: Int(list.startIndex), items: list.children.compactMap { item($0) }
            ))
        case let table as Markdown.Table:
            return ContentBlock(id: id, span: span, kind: tableKind(table))
        case is ThematicBreak:
            return ContentBlock(id: id, span: span, kind: .thematicBreak)
        case let html as HTMLBlock:
            return ContentBlock(id: id, span: span, kind: .htmlBlock(text: html.rawHTML))
        default:
            // Unknown block (directives etc.): degrade to its plain text.
            let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ContentBlock(id: id, span: span, kind: .paragraph(
                inlines: [InlineNode(span: span, kind: .text(text))]
            ))
        }
    }

    private mutating func item(_ markup: Markup) -> VWParse.ListItem? {
        guard let listItem = markup as? Markdown.ListItem else { return nil }
        let checkbox: Bool? = switch listItem.checkbox {
        case .checked: true
        case .unchecked: false
        case nil: nil
        }
        return VWParse.ListItem(
            checkbox: checkbox,
            children: listItem.children.compactMap { block($0) },
            span: span(listItem)
        )
    }

    private mutating func tableKind(_ table: Markdown.Table) -> ContentBlock.Kind {
        let alignments = table.columnAlignments.map { alignment -> TableAlignment in
            switch alignment {
            case .left: .left
            case .center: .center
            case .right: .right
            case nil: .none
            }
        }
        let head = table.head.children.compactMap { cell -> [InlineNode]? in
            guard let cell = cell as? Markdown.Table.Cell else { return nil }
            return inlines(of: cell)
        }
        let body = table.body.children.compactMap { row -> [[InlineNode]]? in
            guard let row = row as? Markdown.Table.Row else { return nil }
            return row.children.compactMap { cell -> [InlineNode]? in
                guard let cell = cell as? Markdown.Table.Cell else { return nil }
                return inlines(of: cell)
            }
        }
        return .table(alignments: alignments, head: head, body: body)
    }

    // MARK: - Inlines

    private func inlines(of parent: Markup) -> [InlineNode] {
        parent.children.compactMap { inline($0) }
    }

    private func inline(_ markup: Markup) -> InlineNode? {
        let span = span(markup)
        switch markup {
        case let text as Markdown.Text:
            return InlineNode(span: span, kind: .text(text.string))
        case let code as InlineCode:
            return InlineNode(span: span, kind: .code(code.code))
        case let emphasis as Emphasis:
            return InlineNode(span: span, kind: .emphasis(inlines(of: emphasis)))
        case let strong as Strong:
            return InlineNode(span: span, kind: .strong(inlines(of: strong)))
        case let strikethrough as Strikethrough:
            return InlineNode(span: span, kind: .strikethrough(inlines(of: strikethrough)))
        case let link as Markdown.Link:
            return InlineNode(span: span, kind: .link(
                destination: link.destination, children: inlines(of: link)
            ))
        case let image as Markdown.Image:
            let alt = image.children.compactMap { inline($0)?.plainText }.joined()
            return InlineNode(span: span, kind: .image(alt: alt, source: image.source))
        case is SoftBreak:
            return InlineNode(span: span, kind: .softBreak)
        case is LineBreak:
            return InlineNode(span: span, kind: .hardBreak)
        case let html as InlineHTML:
            return InlineNode(span: span, kind: .html(html.rawHTML))
        default:
            let text = markup.format()
            guard !text.isEmpty else { return nil }
            return InlineNode(span: span, kind: .text(text))
        }
    }
}
