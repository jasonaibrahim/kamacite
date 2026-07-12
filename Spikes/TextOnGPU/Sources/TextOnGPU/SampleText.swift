import AppKit
import CoreText

struct Theme {
    let name: String
    /// sRGB. Also used verbatim as the Metal clear color (we render into a
    /// non-sRGB view of the drawable, so encoded values pass through untouched).
    let background: CGColor
    let text: NSColor
    let secondary: NSColor

    static let dark = Theme(
        name: "dark",
        background: CGColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1),
        text: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.93, alpha: 1),
        secondary: NSColor(srgbRed: 0.58, green: 0.58, blue: 0.60, alpha: 1)
    )

    static let light = Theme(
        name: "light",
        background: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        text: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1),
        secondary: NSColor(srgbRed: 0.42, green: 0.42, blue: 0.44, alpha: 1)
    )
}

/// The hardcoded mixed string the spike exists to render: latin, ligatures,
/// bold/italic, arabic (shaped + RTL), CJK (font fallback), emoji (color
/// glyphs, ZWJ sequences, flags, skin tones), mono, and small secondary text —
/// the last being where gamma/weight errors are most visible.
enum SampleText {
    static func build(theme: Theme) -> NSAttributedString {
        let result = NSMutableAttributedString()

        func append(_ text: String, font: NSFont, color: NSColor) {
            result.append(NSAttributedString(string: text, attributes: [
                .font: font,
                // Both keys: .foregroundColor for the NSTextView reference pane,
                // the CT key so CTLineDraw and our run extraction see a CGColor.
                .foregroundColor: color,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            ]))
        }

        let title = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let body = NSFont.systemFont(ofSize: 13)
        let bodyBold = NSFont.systemFont(ofSize: 13, weight: .bold)
        let bodyItalic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let small = NSFont.systemFont(ofSize: 11)

        append("vw text-on-GPU spike\n", font: title, color: theme.text)
        append("The quick brown fox jumps over the lazy dog. ", font: body, color: theme.text)
        append("Efficient offices affirm difficult ligatures: fi ffi fl ffl.\n", font: body, color: theme.text)
        append("Bold weight check. ", font: bodyBold, color: theme.text)
        append("Italic slant check. ", font: bodyItalic, color: theme.text)
        append("Regular again for contrast.\n", font: body, color: theme.text)
        append("مرحباً بالعالم — النص العربي يُشكَّل بحروف متصلة من اليمين إلى اليسار\n", font: body, color: theme.text)
        append("日本語の文字、中文文本，한국어 텍스트。\n", font: body, color: theme.text)
        append("Emoji: 🚀🔥✨🎉 tones 👍🏽👋🏿 zwj 👨‍👩‍👧‍👦 flag 🇺🇸 heart ❤️\n", font: body, color: theme.text)
        append("let Δ = φ × π  // monospaced, math glyphs\n", font: mono, color: theme.text)
        append("Small secondary text at 11pt — the first place gamma errors show as thin or fat strokes.\n", font: small, color: theme.secondary)

        return result
    }
}
