import CoreGraphics

// Mermaid diagram identity. A mermaid fence flattens to a plain `.codeBlock`
// (zero first-paint cost); the session later swaps the block to `.diagram`,
// attaching a DiagramInfo that names the raster the renderer should draw.

/// Identity + intrinsic geometry of a rendered diagram raster.
public struct DiagramInfo: Sendable, Equatable, Hashable {
    /// Stable identity of the raster: fnv1a64 over (source, isDark, pixelScale bucket).
    public var imageKey: UInt64
    /// Intrinsic size in points at the zoom level current when rasterized.
    public var naturalSizePts: CGSize

    public init(imageKey: UInt64, naturalSizePts: CGSize) {
        self.imageKey = imageKey
        self.naturalSizePts = naturalSizePts
    }

    // CGSize is not Hashable; hash the components.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(imageKey)
        hasher.combine(naturalSizePts.width)
        hasher.combine(naturalSizePts.height)
    }
}

/// Raster identity for a diagram: FNV-1a 64 over the source's UTF-8 bytes,
/// a 0x1F separator, a theme byte (`d`/`l`), another separator, and the
/// pixel-scale bucket (quarter-scale resolution) as decimal UTF-8.
/// Deterministic across processes (do NOT use Hasher — it is seed-randomized).
public func diagramImageKey(source: String, isDark: Bool, pixelScale: CGFloat) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ byte: UInt8) {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    for byte in source.utf8 { mix(byte) }
    mix(0x1F)
    mix(isDark ? 0x64 : 0x6C)
    mix(0x1F)
    for byte in String(Int((pixelScale * 4).rounded())).utf8 { mix(byte) }
    return hash
}

/// Whether a fence info string names a mermaid diagram: its first
/// whitespace-delimited token, lowercased, is "mermaid" — so "Mermaid" and
/// "mermaid theme=x" qualify; nil does not.
public func isMermaidLanguage(_ language: String?) -> Bool {
    guard let language,
          let token = language.split(whereSeparator: \.isWhitespace).first
    else { return false }
    return token.lowercased() == "mermaid"
}
