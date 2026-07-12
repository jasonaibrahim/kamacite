import CoreGraphics
import VWCore
import VWStyle
import VWText

// P2: eager layout — every block shaped up front. P3 replaces the eager loop
// with the BlockGeometryTree + viewport-only LayoutStore; layoutBlock stays a
// pure function either way.

public struct BlockLayout: Sendable {
    public let flatIndex: Int
    public let id: BlockID
    public let kind: FlatBlockKind
    /// Block top in document space, points.
    public let yPts: CGFloat
    public let heightPts: CGFloat
    /// Where the shaped text sits inside the block (indent + padding), points.
    public let textInsetPts: CGPoint
    /// Painted below the text (code background, rule ink), block-relative.
    public let background: BackgroundQuad?
    public let shaped: ShapedBlockText

    public var maxYPts: CGFloat { yPts + heightPts }
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

public func layoutDocument(
    _ document: FlatDocument,
    fonts: FontTable,
    metrics: Metrics,
    contentWidth: CGFloat,
    scale: CGFloat
) -> DocumentLayout {
    var blocks: [BlockLayout] = []
    blocks.reserveCapacity(document.blocks.count)
    var y: CGFloat = 0

    for (index, flat) in document.blocks.enumerated() {
        if !blocks.isEmpty {
            y += spacingBefore(flat.kind, metrics: metrics)
        }

        let indent = CGFloat(flat.indentLevel) * metrics.indentWidth
        let padding = flat.kind == .codeBlock ? metrics.codeBlockPadding : 0
        let textWidth = max(40, contentWidth - indent - padding * 2)
        let shaped = shapeBlock(flat, fonts: fonts, width: textWidth, scale: scale)

        let height: CGFloat
        var background: BackgroundQuad?
        switch flat.kind {
        case .rule:
            height = metrics.ruleThickness
            background = BackgroundQuad(
                rectPts: CGRect(x: indent, y: 0, width: max(0, contentWidth - indent), height: height),
                color: .rule
            )
        case .codeBlock:
            height = shaped.heightPts + padding * 2
            background = BackgroundQuad(
                rectPts: CGRect(x: indent, y: 0, width: max(0, contentWidth - indent), height: height),
                color: .codeBackground
            )
        default:
            height = shaped.heightPts + padding * 2
        }

        blocks.append(BlockLayout(
            flatIndex: index,
            id: flat.id,
            kind: flat.kind,
            yPts: y,
            heightPts: height,
            textInsetPts: CGPoint(x: indent + padding, y: padding),
            background: background,
            shaped: shaped
        ))
        y += height + spacingAfter(flat.kind, metrics: metrics)
    }

    return DocumentLayout(blocks: blocks, contentWidthPts: contentWidth, contentHeightPts: y)
}

private func spacingBefore(_ kind: FlatBlockKind, metrics: Metrics) -> CGFloat {
    switch kind {
    case .heading: metrics.headingSpacingBefore
    case .rule: metrics.ruleSpacing
    default: 0
    }
}

private func spacingAfter(_ kind: FlatBlockKind, metrics: Metrics) -> CGFloat {
    switch kind {
    case .heading: metrics.headingSpacingAfter
    case .paragraph: metrics.paragraphSpacing
    case .codeBlock: metrics.codeBlockSpacing
    case .listItem: metrics.listItemSpacing
    case .tableRow: 2
    case .rule: metrics.ruleSpacing
    }
}
