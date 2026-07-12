import Foundation
import VWCore
import VWParse

// Flattening is what makes lazy layout possible: nested structure (quotes,
// lists) becomes a LINEAR array of blocks with indent depths and decorations,
// O(1)-indexable by block number. Each FlatBlock is one shaping unit.

public struct FlatDocument: Sendable {
    public var blocks: [FlatBlock]

    public init(blocks: [FlatBlock]) {
        self.blocks = blocks
    }
}

public struct FlatBlock: Sendable {
    public var id: BlockID
    public var span: SourceSpan
    public var kind: FlatBlockKind
    public var quoteDepth: Int
    public var listDepth: Int
    public var runs: [StyledRun]

    /// The font class shaping uses for the line grid; runs may add traits.
    public var baseFontClass: FontClass {
        switch kind {
        case .heading(let level): .heading(level)
        case .codeBlock: .code
        case .tableRow: .code
        default: .body
        }
    }

    public var indentLevel: Int { quoteDepth + listDepth }

    public init(
        id: BlockID, span: SourceSpan, kind: FlatBlockKind,
        quoteDepth: Int = 0, listDepth: Int = 0, runs: [StyledRun]
    ) {
        self.id = id
        self.span = span
        self.kind = kind
        self.quoteDepth = quoteDepth
        self.listDepth = listDepth
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

    public init(text: String, traits: RunTraits = [], color: ColorToken = .text, span: SourceSpan? = nil) {
        self.text = text
        self.traits = traits
        self.color = color
        self.span = span
    }
}

public func flatten(_ tree: ContentTree) -> FlatDocument {
    var flattener = Flattener()
    for block in tree.blocks {
        flattener.flatten(block)
    }
    return FlatDocument(blocks: flattener.output)
}

private struct Flattener {
    var output: [FlatBlock] = []
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

        case .codeBlock(_, let code):
            var text = code
            if text.hasSuffix("\n") { text.removeLast() }
            emit(block, kind: .codeBlock, runs: [
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

        case .table(_, let head, let body):
            // Degraded rendering until P5: one mono row per table row.
            if !head.isEmpty {
                emit(block, kind: .tableRow, runs: rowRuns(head, bold: true))
            }
            for row in body where !row.isEmpty {
                emit(block, kind: .tableRow, runs: rowRuns(row, bold: false))
            }

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
        let markerRun = StyledRun(text: marker, traits: [], color: .secondaryText, span: nil)
        var children = item.children[...]

        if let first = children.first, case .paragraph(let inlines) = first.kind {
            children = children.dropFirst()
            emit(first, kind: .listItem, runs: [markerRun] + runs(from: inlines, color: baseColor))
        } else if !marker.isEmpty {
            // Item that doesn't start with a paragraph: marker on its own line.
            let id = children.first?.id ?? BlockID(rawValue: .max)
            output.append(FlatBlock(
                id: id, span: item.span, kind: .listItem,
                quoteDepth: quoteDepth, listDepth: listDepth, runs: [markerRun]
            ))
        }

        listDepth += 1
        for child in children { flatten(child) }
        listDepth -= 1
    }

    private func marker(ordered: Bool, start: Int, index: Int, checkbox: Bool?) -> String {
        if let checkbox {
            return checkbox ? "☑ " : "☐ "
        }
        return ordered ? "\(start + index). " : "•  "
    }

    private mutating func emit(
        _ source: ContentBlock, kind: FlatBlockKind, runs: [StyledRun], allowEmpty: Bool = false
    ) {
        guard allowEmpty || runs.contains(where: { !$0.text.isEmpty }) else { return }
        output.append(FlatBlock(
            id: source.id, span: source.span, kind: kind,
            quoteDepth: quoteDepth, listDepth: listDepth, runs: runs
        ))
    }

    private func rowRuns(_ cells: [[InlineNode]], bold: Bool) -> [StyledRun] {
        let text = cells.map { $0.map(\.plainText).joined() }.joined(separator: "   ")
        return [StyledRun(text: text, traits: bold ? [.mono, .bold] : .mono, color: .codeText, span: nil)]
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
            case .link(_, let children):
                // Styled now, clickable in P4.
                appendRuns(from: children, traits: traits, color: .accent, into: &collected)
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
