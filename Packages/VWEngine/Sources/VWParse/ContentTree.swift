import VWCore

// The compact, theme-free document IR. swift-markdown's AST is converted into
// this and dropped immediately — these are plain Sendable value types with no
// class graph to retain, and every node carries its UTF-8 SourceSpan (the
// anchor coordinate for future editing/commenting).

public struct ContentTree: Sendable, Equatable {
    public var blocks: [ContentBlock]
    /// UTF-8 length of the source the spans index into.
    public var sourceUTF8Count: Int

    public init(blocks: [ContentBlock], sourceUTF8Count: Int) {
        self.blocks = blocks
        self.sourceUTF8Count = sourceUTF8Count
    }
}

public struct ContentBlock: Sendable, Equatable {
    public var id: BlockID
    public var span: SourceSpan
    public var kind: Kind

    public indirect enum Kind: Sendable, Equatable {
        case heading(level: Int, inlines: [InlineNode])
        case paragraph(inlines: [InlineNode])
        /// `code` keeps cmark's trailing newline; consumers trim for display.
        case codeBlock(language: String?, code: String)
        case blockquote(children: [ContentBlock])
        case list(ordered: Bool, start: Int, items: [ListItem])
        case table(alignments: [TableAlignment], head: [[InlineNode]], body: [[[InlineNode]]])
        case thematicBreak
        case htmlBlock(text: String)
    }

    public init(id: BlockID, span: SourceSpan, kind: Kind) {
        self.id = id
        self.span = span
        self.kind = kind
    }
}

public struct ListItem: Sendable, Equatable {
    /// nil = plain item; true/false = GFM task-list checkbox state.
    public var checkbox: Bool?
    public var children: [ContentBlock]
    public var span: SourceSpan

    public init(checkbox: Bool?, children: [ContentBlock], span: SourceSpan) {
        self.checkbox = checkbox
        self.children = children
        self.span = span
    }
}

public enum TableAlignment: Sendable, Equatable {
    case none, left, center, right
}

public struct InlineNode: Sendable, Equatable {
    public var span: SourceSpan
    public var kind: Kind

    public indirect enum Kind: Sendable, Equatable {
        case text(String)
        case code(String)
        case emphasis([InlineNode])
        case strong([InlineNode])
        case strikethrough([InlineNode])
        case link(destination: String?, children: [InlineNode])
        case image(alt: String, source: String?)
        case softBreak
        case hardBreak
        case html(String)
    }

    public init(span: SourceSpan, kind: Kind) {
        self.span = span
        self.kind = kind
    }
}

extension InlineNode {
    /// Concatenated visible text (for alt-text, tests, and degraded rendering).
    public var plainText: String {
        switch kind {
        case .text(let s), .code(let s), .html(let s):
            return s
        case .emphasis(let children), .strong(let children), .strikethrough(let children),
             .link(_, let children):
            return children.map(\.plainText).joined()
        case .image(let alt, _):
            return alt
        case .softBreak, .hardBreak:
            return " "
        }
    }
}
