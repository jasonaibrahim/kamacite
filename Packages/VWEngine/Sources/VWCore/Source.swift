/// A half-open byte range into the original markdown file (UTF-8 offsets).
///
/// The canonical anchor coordinate of the whole system: every pipeline stage threads
/// these through, and future editing/commenting features anchor to them. UTF-8 byte
/// offsets survive re-parse diffing and are what would be persisted.
public struct SourceSpan: Hashable, Sendable {
    public var startUTF8: Int
    /// Exclusive.
    public var endUTF8: Int

    public init(startUTF8: Int, endUTF8: Int) {
        precondition(startUTF8 <= endUTF8, "SourceSpan must be non-decreasing")
        self.startUTF8 = startUTF8
        self.endUTF8 = endUTF8
    }

    public var isEmpty: Bool { startUTF8 == endUTF8 }
    public var length: Int { endUTF8 - startUTF8 }
}

/// Stable per-parse identifier for a block; assigned monotonically by VWParse.
public struct BlockID: Hashable, Sendable, RawRepresentable {
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// A caret-addressable position in the rendered document: a block plus a UTF-16
/// offset into that block's text content. (Text content uses UTF-16 — the
/// CoreText/CFString coordinate space; source positions use UTF-8 byte spans.)
public struct TextPosition: Comparable, Hashable, Sendable {
    public var blockIndex: Int
    public var utf16Offset: Int

    public init(blockIndex: Int, utf16Offset: Int) {
        self.blockIndex = blockIndex
        self.utf16Offset = utf16Offset
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        (lhs.blockIndex, lhs.utf16Offset) < (rhs.blockIndex, rhs.utf16Offset)
    }
}
