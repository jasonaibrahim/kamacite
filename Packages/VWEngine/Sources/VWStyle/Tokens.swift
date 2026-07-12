// Style tokens. Colors are TOKENS (a dark/light flip is a re-render with a new
// palette — no re-layout); fonts are SLOTS resolved through FontTable (a font
// change is a re-layout — no re-parse).

public enum ColorToken: Sendable, Hashable, CaseIterable {
    case text
    case secondaryText
    case accent
    case codeText
    case pageBackground
    case codeBackground
    case rule
    /// Selected-text background, painted below glyphs.
    case selection
    /// Blockquote gutter bar.
    case quoteBar
    // Syntax highlighting (color-only by design: same fonts, same advances,
    // so applying highlights never changes layout).
    case codeKeyword
    case codeString
    case codeComment
    case codeNumber
}

public struct RunTraits: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let bold = RunTraits(rawValue: 1 << 0)
    public static let italic = RunTraits(rawValue: 1 << 1)
    public static let mono = RunTraits(rawValue: 1 << 2)
    /// Drawn as a solid quad by the renderer — CoreText doesn't paint it.
    public static let strikethrough = RunTraits(rawValue: 1 << 3)
}

public enum FontClass: Sendable, Hashable {
    case body
    case heading(Int) // 1...6
    case code
}
