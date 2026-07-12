import CoreGraphics
import VWCore
import VWStyle
import VWText

// BlockLayout is the unit the renderer consumes; DocumentLayout is a fully
// materialized slice of the document (a frame's visible blocks, or — for tests
// and snapshots — the whole thing via layoutDocument()).

public struct BlockLayout: Sendable {
    public let flatIndex: Int
    public let id: BlockID
    public let kind: FlatBlockKind
    /// Block top in document space, points.
    public let yPts: CGFloat
    public let heightPts: CGFloat
    /// Where the shaped text sits inside the block (indent + padding), points.
    public let textInsetPts: CGPoint
    /// Painted below the text (code background, quote bars, rule ink),
    /// block-relative, in array order.
    public let backgrounds: [BackgroundQuad]
    public let shaped: ShapedBlockText

    public var maxYPts: CGFloat { yPts + heightPts }

    public init(
        flatIndex: Int, id: BlockID, kind: FlatBlockKind, yPts: CGFloat,
        heightPts: CGFloat, textInsetPts: CGPoint, backgrounds: [BackgroundQuad],
        shaped: ShapedBlockText
    ) {
        self.flatIndex = flatIndex
        self.id = id
        self.kind = kind
        self.yPts = yPts
        self.heightPts = heightPts
        self.textInsetPts = textInsetPts
        self.backgrounds = backgrounds
        self.shaped = shaped
    }
}

public struct BackgroundQuad: Sendable {
    /// Block-relative, points.
    public let rectPts: CGRect
    public let color: ColorToken

    public init(rectPts: CGRect, color: ColorToken) {
        self.rectPts = rectPts
        self.color = color
    }
}

public struct DocumentLayout: Sendable {
    public let blocks: [BlockLayout]
    public let contentWidthPts: CGFloat
    public let contentHeightPts: CGFloat

    public init(blocks: [BlockLayout], contentWidthPts: CGFloat, contentHeightPts: CGFloat) {
        self.blocks = blocks
        self.contentWidthPts = contentWidthPts
        self.contentHeightPts = contentHeightPts
    }
}

/// Eager whole-document layout: the lazy path with everything forced exact.
/// Tests and snapshots use this; the app never should.
@MainActor
public func layoutDocument(
    _ document: FlatDocument,
    fonts: FontTable,
    metrics: Metrics,
    contentWidth: CGFloat,
    scale: CGFloat
) -> DocumentLayout {
    let lazy = LazyLayout(
        document: document, fonts: fonts, metrics: metrics,
        contentWidth: contentWidth, scale: scale
    )
    lazy.prepare(docRange: 0..<CGFloat.greatestFiniteMagnitude, anchorY: 0)
    let blocks = lazy.placedBlocks(in: 0..<CGFloat.greatestFiniteMagnitude)
    return DocumentLayout(
        blocks: blocks,
        contentWidthPts: contentWidth,
        contentHeightPts: lazy.contentHeightPts
    )
}
