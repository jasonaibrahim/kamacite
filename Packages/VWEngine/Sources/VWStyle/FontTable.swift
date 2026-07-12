import CoreText
import Foundation

/// Resolves (FontClass, RunTraits) → CTFont, cached. Headless-safe: uses
/// CTFontCreateUIFontForLanguage (SF / fixed-pitch UI fonts), never AppKit.
///
/// CTFont is immutable and thread-safe; the cache is lock-guarded, hence
/// @unchecked Sendable.
public final class FontTable: @unchecked Sendable {
    private struct Key: Hashable {
        let fontClass: FontClass
        let traits: RunTraits
    }

    private let metrics: Metrics
    private let lock = NSLock()
    private var cache: [Key: CTFont] = [:]

    public init(metrics: Metrics) {
        self.metrics = metrics
    }

    public func font(for fontClass: FontClass, traits: RunTraits) -> CTFont {
        let key = Key(fontClass: fontClass, traits: traits)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] {
            return cached
        }
        let font = makeFont(fontClass: fontClass, traits: traits)
        cache[key] = font
        return font
    }

    private func makeFont(fontClass: FontClass, traits: RunTraits) -> CTFont {
        var size = metrics.size(for: fontClass)
        let mono = traits.contains(.mono) || fontClass == .code
        if mono, fontClass != .code {
            // Inline code inside prose: fixed-pitch faces run visually larger
            // than SF at equal point size; 87% reads as the same optical size.
            size = (size * 0.87).rounded()
        }

        var base: CTFont
        if mono {
            // The system-UI monospaced face isn't reachable through public
            // CoreText UI-font types; user-fixed-pitch (Menlo) is the stable
            // headless-safe choice.
            base = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
                ?? CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        } else {
            base = CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }

        var symbolic: CTFontSymbolicTraits = []
        var isHeading = false
        if case .heading(let level) = fontClass {
            isHeading = true
            // h1/h2 are semibold via weight below; h3+ take the plain bold trait.
            if level >= 3 { symbolic.insert(.traitBold) }
        }
        if traits.contains(.bold) { symbolic.insert(.traitBold) }
        if traits.contains(.italic) { symbolic.insert(.traitItalic) }

        if !symbolic.isEmpty,
           let adjusted = CTFontCreateCopyWithSymbolicTraits(base, size, nil, symbolic, symbolic) {
            base = adjusted
        }

        if isHeading, case .heading(let level) = fontClass, level <= 2, !traits.contains(.bold) {
            // Semibold for the large headings — bold at 28pt is shouty.
            let weightAttributes = [
                kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.3] // ~semibold
            ] as CFDictionary
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(base), weightAttributes
            )
            base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }

        return base
    }

    /// Fixed line slot for a block's base font: uniform vertical rhythm even
    /// when fallback fonts (CJK, emoji) have taller metrics.
    public func lineSlot(for fontClass: FontClass) -> (height: CGFloat, ascent: CGFloat) {
        let font = font(for: fontClass, traits: [])
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let natural = ascent + descent + leading
        let height = (natural * metrics.lineHeightMultiple(for: fontClass)).rounded()
        // Center the natural extent in the slot; baseline sits ascent below that.
        let baselineOffset = ((height - natural) / 2 + ascent).rounded()
        return (height, baselineOffset)
    }
}
