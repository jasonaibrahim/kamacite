import Foundation
import VWCore
import VWParse

// Flattening is what makes lazy layout possible: nested structure (quotes,
// lists) becomes a LINEAR array of blocks with indent depths and decorations,
// O(1)-indexable by block number. Each FlatBlock is one shaping unit.

public struct FlatDocument: Sendable {
    public var blocks: [FlatBlock]
    /// One entry per source table; rows reference these by index.
    public var tables: [FlatTable]

    public init(blocks: [FlatBlock], tables: [FlatTable] = []) {
        self.blocks = blocks
        self.tables = tables
    }
}

public struct FlatTable: Sendable, Equatable {
    public var alignments: [TableAlignment]
    /// Rows are contiguous flat blocks starting here — column measurement
    /// samples them without scanning the document.
    public var firstRowFlatIndex: Int
    public var rowCount: Int

    public init(alignments: [TableAlignment], firstRowFlatIndex: Int, rowCount: Int) {
        self.alignments = alignments
        self.firstRowFlatIndex = firstRowFlatIndex
        self.rowCount = rowCount
    }
}

public struct TableRowInfo: Sendable, Equatable {
    public var tableIndex: Int
    public var rowIndex: Int
    public var isHeader: Bool
    public var isLastRow: Bool
    /// Styled runs per cell. `FlatBlock.runs` holds the same runs joined with
    /// tab separators — copy and estimation work on rows like any block.
    public var cells: [[StyledRun]]

    public init(tableIndex: Int, rowIndex: Int, isHeader: Bool, isLastRow: Bool, cells: [[StyledRun]]) {
        self.tableIndex = tableIndex
        self.rowIndex = rowIndex
        self.isHeader = isHeader
        self.isLastRow = isLastRow
        self.cells = cells
    }
}

public struct FlatBlock: Sendable {
    public var id: BlockID
    public var span: SourceSpan
    public var kind: FlatBlockKind
    public var quoteDepth: Int
    public var listDepth: Int
    /// List bullet/number/checkbox, drawn right-aligned in the indent column
    /// before the text — NOT part of `runs`, so wrapped lines hang correctly.
    public var marker: String?
    /// Fence info string for code blocks; drives async syntax highlighting.
    public var codeLanguage: String?
    /// Structured cell data for `.tableRow` blocks.
    public var tableRow: TableRowInfo?
    public var runs: [StyledRun]

    /// The font class shaping uses for the line grid; runs may add traits.
    public var baseFontClass: FontClass {
        switch kind {
        case .heading(let level): .heading(level)
        case .codeBlock: .code
        default: .body
        }
    }

    /// Indent units for the TEXT. List items indent one unit past their
    /// marker column so wrapped lines align under the first character.
    public var indentLevel: Int {
        quoteDepth + listDepth + (kind == .listItem ? 1 : 0)
    }

    public init(
        id: BlockID, span: SourceSpan, kind: FlatBlockKind,
        quoteDepth: Int = 0, listDepth: Int = 0,
        marker: String? = nil, codeLanguage: String? = nil,
        tableRow: TableRowInfo? = nil, runs: [StyledRun]
    ) {
        self.id = id
        self.span = span
        self.kind = kind
        self.quoteDepth = quoteDepth
        self.listDepth = listDepth
        self.marker = marker
        self.codeLanguage = codeLanguage
        self.tableRow = tableRow
        self.runs = runs
    }
}

public enum FlatBlockKind: Sendable, Equatable {
    case paragraph
    case heading(Int)
    case codeBlock
    case listItem
    /// P2 degraded table rendering (mono, cells joined); P5 replaces with real
    /// column layout.
    case tableRow
    case rule
}

public struct StyledRun: Sendable, Equatable {
    public var text: String
    public var traits: RunTraits
    public var color: ColorToken
    public var span: SourceSpan?
    /// Destination for link runs — hover cursor + click-to-open.
    public var link: String?

    public init(
        text: String, traits: RunTraits = [], color: ColorToken = .text,
        span: SourceSpan? = nil, link: String? = nil
    ) {
        self.text = text
        self.traits = traits
        self.color = color
        self.span = span
        self.link = link
    }
}

public func flatten(_ tree: ContentTree) -> FlatDocument {
    var flattener = Flattener()
    for block in tree.blocks {
        flattener.flatten(block)
    }
    return FlatDocument(blocks: flattener.output, tables: flattener.tables)
}

private struct Flattener {
    var output: [FlatBlock] = []
    var tables: [FlatTable] = []
    private var quoteDepth = 0
    private var listDepth = 0
    /// Quoted content reads as secondary; P4 adds the vertical bar.
    private var baseColor: ColorToken { quoteDepth > 0 ? .secondaryText : .text }

    mutating func flatten(_ block: ContentBlock) {
        switch block.kind {
        case .heading(let level, let inlines):
            let color: ColorToken = level >= 6 ? .secondaryText : baseColor
            emit(block, kind: .heading(level), runs: runs(from: inlines, color: color))

        case .paragraph(let inlines):
            emit(block, kind: .paragraph, runs: runs(from: inlines, color: baseColor))

        case .codeBlock(let language, let code):
            var text = code
            if text.hasSuffix("\n") { text.removeLast() }
            emit(block, kind: .codeBlock, language: language, runs: [
                StyledRun(text: text, traits: .mono, color: .codeText, span: block.span)
            ])

        case .blockquote(let children):
            quoteDepth += 1
            for child in children { flatten(child) }
            quoteDepth -= 1

        case .list(let ordered, let start, let items):
            for (index, item) in items.enumerated() {
                flattenListItem(item, marker: marker(ordered: ordered, start: start, index: index, checkbox: item.checkbox))
            }

        case .table(let alignments, let head, let body):
            flattenTable(block, alignments: alignments, head: head, body: body)

        case .thematicBreak:
            emit(block, kind: .rule, runs: [], allowEmpty: true)

        case .htmlBlock(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            emit(block, kind: .paragraph, runs: [
                StyledRun(text: trimmed, traits: .mono, color: .secondaryText, span: block.span)
            ])
        }
    }

    private mutating func flattenListItem(_ item: ListItem, marker: String) {
        var children = item.children[...]

        if let first = children.first, case .paragraph(let inlines) = first.kind {
            children = children.dropFirst()
            emit(first, kind: .listItem, marker: marker, runs: runs(from: inlines, color: baseColor))
        } else if !marker.isEmpty {
            // Item that doesn't start with a paragraph: marker on its own line.
            let id = children.first?.id ?? BlockID(rawValue: .max)
            output.append(FlatBlock(
                id: id, span: item.span, kind: .listItem,
                quoteDepth: quoteDepth, listDepth: listDepth, marker: marker,
                runs: [StyledRun(text: " ", traits: [], color: baseColor, span: nil)]
            ))
        }

        listDepth += 1
        for child in children { flatten(child) }
        listDepth -= 1
    }

    private func marker(ordered: Bool, start: Int, index: Int, checkbox: Bool?) -> String {
        if let checkbox {
            return checkbox ? "☑" : "☐"
        }
        if ordered {
            return "\(start + index)."
        }
        // Bullet glyph cycles with nesting depth, like every serious reader.
        return ["•", "◦", "▪"][listDepth % 3]
    }

    private mutating func emit(
        _ source: ContentBlock, kind: FlatBlockKind, marker: String? = nil,
        language: String? = nil, runs: [StyledRun], allowEmpty: Bool = false
    ) {
        guard allowEmpty || runs.contains(where: { !$0.text.isEmpty }) else { return }
        output.append(FlatBlock(
            id: source.id, span: source.span, kind: kind,
            quoteDepth: quoteDepth, listDepth: listDepth,
            marker: marker, codeLanguage: language, runs: runs
        ))
    }

    private mutating func flattenTable(
        _ block: ContentBlock, alignments: [TableAlignment],
        head: [[InlineNode]], body: [[[InlineNode]]]
    ) {
        let columnCount = max(alignments.count, head.count)
        guard columnCount > 0 else { return }

        var rows: [(cells: [[InlineNode]], isHeader: Bool)] = []
        if !head.isEmpty {
            rows.append((head, true))
        }
        for row in body where !row.isEmpty {
            rows.append((row, false))
        }
        guard !rows.isEmpty else { return }

        let tableIndex = tables.count
        tables.append(FlatTable(
            alignments: alignments,
            firstRowFlatIndex: output.count,
            rowCount: rows.count
        ))

        for (rowIndex, row) in rows.enumerated() {
            // Every row gets exactly columnCount cells; short rows pad out.
            var cells: [[StyledRun]] = []
            for column in 0..<columnCount {
                let inlines = column < row.cells.count ? row.cells[column] : []
                var cellRuns: [StyledRun] = []
                appendRuns(
                    from: inlines,
                    traits: row.isHeader ? .bold : [],
                    color: baseColor,
                    into: &cellRuns
                )
                cells.append(cellRuns)
            }

            // Joined runs (tab-separated): estimation and plain-text copy see
            // one ordinary block; the tabs paste cleanly into spreadsheets.
            var joined: [StyledRun] = []
            for (column, cellRuns) in cells.enumerated() {
                if column > 0 {
                    joined.append(StyledRun(text: "\t", traits: [], color: baseColor, span: nil))
                }
                joined.append(contentsOf: cellRuns)
            }

            output.append(FlatBlock(
                id: block.id, span: block.span, kind: .tableRow,
                quoteDepth: quoteDepth, listDepth: listDepth,
                tableRow: TableRowInfo(
                    tableIndex: tableIndex,
                    rowIndex: rowIndex,
                    isHeader: row.isHeader,
                    isLastRow: rowIndex == rows.count - 1,
                    cells: cells
                ),
                runs: joined
            ))
        }
    }

    // MARK: - Inline runs

    private func runs(from inlines: [InlineNode], color: ColorToken) -> [StyledRun] {
        var collected: [StyledRun] = []
        appendRuns(from: inlines, traits: [], color: color, into: &collected)
        return collected
    }

    private func appendRuns(
        from inlines: [InlineNode], traits: RunTraits, color: ColorToken, into collected: inout [StyledRun]
    ) {
        for node in inlines {
            switch node.kind {
            case .text(let text):
                collected.append(StyledRun(text: text, traits: traits, color: color, span: node.span))
            case .code(let code):
                collected.append(StyledRun(
                    text: code, traits: traits.union(.mono), color: .codeText, span: node.span
                ))
            case .emphasis(let children):
                appendRuns(from: children, traits: traits.union(.italic), color: color, into: &collected)
            case .strong(let children):
                appendRuns(from: children, traits: traits.union(.bold), color: color, into: &collected)
            case .strikethrough(let children):
                appendRuns(from: children, traits: traits.union(.strikethrough), color: color, into: &collected)
            case .link(let destination, let children):
                let before = collected.count
                appendRuns(from: children, traits: traits, color: .accent, into: &collected)
                if let destination {
                    for i in before..<collected.count {
                        collected[i].link = destination
                    }
                }
            case .image(let alt, _):
                let label = alt.isEmpty ? "[image]" : "[\(alt)]"
                collected.append(StyledRun(text: label, traits: traits.union(.italic), color: .secondaryText, span: node.span))
            case .softBreak:
                collected.append(StyledRun(text: " ", traits: traits, color: color, span: node.span))
            case .hardBreak:
                collected.append(StyledRun(text: "\n", traits: traits, color: color, span: node.span))
            case .html(let text):
                collected.append(StyledRun(text: text, traits: traits.union(.mono), color: .secondaryText, span: node.span))
            }
        }
    }
}
