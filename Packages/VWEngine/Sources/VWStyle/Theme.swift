import CoreGraphics

/// A resolved theme: palette (sRGB, consumed directly by the gamma-space
/// renderer) plus typographic metrics in points.
public struct Theme: Sendable, Equatable {
    public var name: String
    public var isDark: Bool
    public var metrics: Metrics

    private var colors: [SIMD4<Float>] // indexed by ColorToken order

    public func color(_ token: ColorToken) -> SIMD4<Float> {
        colors[ColorToken.allCases.firstIndex(of: token)!]
    }

    public init(name: String, isDark: Bool, metrics: Metrics = Metrics(), palette: [ColorToken: SIMD4<Float>]) {
        self.name = name
        self.isDark = isDark
        self.metrics = metrics
        self.colors = ColorToken.allCases.map { palette[$0] ?? SIMD4(1, 0, 1, 1) }
    }

    public static let dark = Theme(name: "dark", isDark: true, palette: [
        .text: SIMD4(0.925, 0.925, 0.93, 1),
        .secondaryText: SIMD4(0.62, 0.62, 0.64, 1),
        .accent: SIMD4(0.35, 0.62, 1.0, 1),
        .codeText: SIMD4(0.88, 0.87, 0.82, 1),
        .pageBackground: SIMD4(0.118, 0.118, 0.125, 1),
        .codeBackground: SIMD4(0.165, 0.165, 0.175, 1),
        .rule: SIMD4(0.30, 0.30, 0.32, 1),
        .selection: SIMD4(0.22, 0.36, 0.55, 1),
        .quoteBar: SIMD4(0.36, 0.36, 0.40, 1),
        .checkboxBorder: SIMD4(0.45, 0.45, 0.50, 1),
        .checkboxCheck: SIMD4(1, 1, 1, 1),
        .codeKeyword: SIMD4(1.0, 0.48, 0.70, 1),
        .codeString: SIMD4(1.0, 0.53, 0.44, 1),
        .codeComment: SIMD4(0.50, 0.56, 0.60, 1),
        .codeNumber: SIMD4(0.85, 0.79, 0.49, 1),
    ])

    public static let light = Theme(name: "light", isDark: false, palette: [
        .text: SIMD4(0.10, 0.10, 0.11, 1),
        .secondaryText: SIMD4(0.42, 0.42, 0.44, 1),
        .accent: SIMD4(0.04, 0.40, 0.85, 1),
        .codeText: SIMD4(0.18, 0.15, 0.35, 1),
        .pageBackground: SIMD4(1, 1, 1, 1),
        .codeBackground: SIMD4(0.955, 0.955, 0.965, 1),
        .rule: SIMD4(0.84, 0.84, 0.86, 1),
        .selection: SIMD4(0.70, 0.84, 1.0, 1),
        .quoteBar: SIMD4(0.80, 0.80, 0.83, 1),
        .checkboxBorder: SIMD4(0.70, 0.70, 0.75, 1),
        .checkboxCheck: SIMD4(1, 1, 1, 1),
        .codeKeyword: SIMD4(0.68, 0.24, 0.64, 1),
        .codeString: SIMD4(0.77, 0.10, 0.09, 1),
        .codeComment: SIMD4(0.36, 0.42, 0.47, 1),
        .codeNumber: SIMD4(0.15, 0.16, 0.85, 1),
    ])
}

/// Typography and spacing, all in points.
public struct Metrics: Sendable, Equatable {
    public var bodySize: CGFloat = 15
    public var codeSize: CGFloat = 13
    /// h1...h6.
    public var headingSizes: [CGFloat] = [28, 22, 18, 16, 14, 13]
    public var bodyLineHeightMultiple: CGFloat = 1.5
    public var headingLineHeightMultiple: CGFloat = 1.25
    public var codeLineHeightMultiple: CGFloat = 1.45

    public var paragraphSpacing: CGFloat = 10
    public var headingSpacingBefore: CGFloat = 16
    public var headingSpacingAfter: CGFloat = 6
    public var codeBlockSpacing: CGFloat = 12
    public var codeBlockPadding: CGFloat = 12
    public var listItemSpacing: CGFloat = 4
    public var ruleSpacing: CGFloat = 14
    public var ruleThickness: CGFloat = 1
    public var indentWidth: CGFloat = 22
    /// Horizontal/vertical padding inside table cells; column widths include
    /// the horizontal component.
    public var tableCellPadding = CGSize(width: 10, height: 5)
    /// Task-list checkbox box edge length.
    public var checkboxSize: CGFloat = 14

    public init() {}

    public func size(for fontClass: FontClass) -> CGFloat {
        switch fontClass {
        case .body: bodySize
        case .code: codeSize
        case .heading(let level): headingSizes[max(1, min(level, 6)) - 1]
        }
    }

    public func lineHeightMultiple(for fontClass: FontClass) -> CGFloat {
        switch fontClass {
        case .body: bodyLineHeightMultiple
        case .code: codeLineHeightMultiple
        case .heading: headingLineHeightMultiple
        }
    }
}
