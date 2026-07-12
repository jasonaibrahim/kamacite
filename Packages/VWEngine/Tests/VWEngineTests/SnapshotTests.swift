import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import VWLayout
import VWParse
import VWRender
import VWStyle

// Golden-image snapshots: full pipeline (parse → flatten → layout → GPU render)
// against checked-in PNGs. Record/refresh with VW_RECORD_GOLDENS=1.
// A missing golden records itself on first run; mismatches write
// <name>.actual.png beside the golden for eyeballing.
//
// Goldens are rasterized by this machine's CoreText — treat them as
// per-toolchain artifacts and re-record after OS font changes.

private let goldensDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Goldens")

private let goldenMarkdown = """
# Golden: every inline

Regular **bold** *italic* ***both*** ~~struck~~ `inline code` and \
[a link](https://example.org) in one paragraph.

## Second heading

- bullet one wrapping onto a second line to prove the hanging indent keeps \
wrapped text aligned under the first character
- bullet two with **bold**
  - nested bullet
    - third level

1. ordered
2. list
10. double-digit marker

- [x] checked task
- [ ] unchecked task

> A quoted line that reads as secondary text.
>
> Second quoted paragraph — the bar must bridge the gap.
> > Nested quote gets a second bar.

```swift
let answer = 42 // mono on a background
```

| col a | col b |
| :---- | ----: |
| one   | two   |

---

Final paragraph after a rule. Emoji: 🚀 CJK: 日本語.
"""

private let goldenCodeMarkdown = """
### Highlighted code

```swift
// Fibonacci, but make it Swift
func fib(_ n: Int) -> Int {
    guard n > 1 else { return n }
    var (a, b) = (0, 1)
    for _ in 2...n { (a, b) = (b, a + b) }
    return b
}
let label = "fib(10) = \\(fib(10))"
```

```python
def load(path: str) -> dict:
    \"\"\"Read a JSON file.\"\"\"
    with open(path) as f:  # utf-8 by default
        return json.load(f)

CACHE_SIZE = 0x400  # 1 KiB
```

```json
{"name": "vw", "fast": true, "budget_ms": 8.33, "deps": null}
```
"""

@Suite struct SnapshotTests {
    @Test @MainActor func goldenDark() throws {
        try assertSnapshot(name: "golden-dark", theme: .dark)
    }

    @Test @MainActor func goldenLight() throws {
        try assertSnapshot(name: "golden-light", theme: .light)
    }

    /// Highlighting applied synchronously here — same transform the session
    /// applies async in the app.
    @Test @MainActor func goldenHighlightedCode() throws {
        try assertSnapshot(
            name: "golden-code-dark", theme: .dark, markdown: goldenCodeMarkdown,
            transform: { document in
                for index in document.blocks.indices
                where document.blocks[index].kind == .codeBlock {
                    guard let language = document.blocks[index].codeLanguage,
                          let code = document.blocks[index].runs.first?.text,
                          let runs = highlightCode(code, language: language)
                    else { continue }
                    document.blocks[index].runs = runs
                }
            }
        )
    }

    @MainActor
    private func assertSnapshot(
        name: String, theme: Theme,
        markdown: String = goldenMarkdown,
        transform: ((inout FlatDocument) -> Void)? = nil
    ) throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            // Headless CI without a GPU: nothing to verify.
            return
        }

        let scale: CGFloat = 2
        let contentWidth: CGFloat = 600
        let insetPts: CGFloat = 24

        var flat = flatten(parseMarkdown(markdown))
        transform?(&flat)
        let fonts = FontTable(metrics: theme.metrics)
        let layout = layoutDocument(
            flat, fonts: fonts, metrics: theme.metrics,
            contentWidth: contentWidth, scale: scale
        )
        let width = Int((contentWidth + insetPts * 2) * scale)
        let height = Int((layout.contentHeightPts + insetPts * 2) * scale)

        let renderer = try DocumentRenderer(scale: scale)
        let texture = renderer.renderOffscreen(
            layout: layout, theme: theme,
            originPts: CGPoint(x: insetPts, y: insetPts),
            scale: scale, width: width, height: height
        )
        let actual = DocumentRenderer.bgraBytes(from: texture)

        let goldenURL = goldensDirectory.appendingPathComponent("\(name).png")
        let recording = ProcessInfo.processInfo.environment["VW_RECORD_GOLDENS"] == "1"

        if recording || !FileManager.default.fileExists(atPath: goldenURL.path) {
            try FileManager.default.createDirectory(at: goldensDirectory, withIntermediateDirectories: true)
            try writePNG(actual, width: width, height: height, to: goldenURL)
            print("snapshot: recorded \(goldenURL.lastPathComponent) (\(width)×\(height))")
            return
        }

        let golden = try readPNG(goldenURL)
        guard golden.width == width, golden.height == height else {
            try writePNG(actual, width: width, height: height,
                         to: goldensDirectory.appendingPathComponent("\(name).actual.png"))
            Issue.record("\(name): size \(width)×\(height) vs golden \(golden.width)×\(golden.height); wrote .actual.png")
            return
        }

        // Tolerate tiny rasterization drift; fail on anything visible.
        var over = 0
        for i in 0..<min(actual.count, golden.pixels.count) where abs(Int(actual[i]) - Int(golden.pixels[i])) > 3 {
            over += 1
        }
        let fraction = Double(over) / Double(actual.count)
        if fraction > 0.0005 {
            try writePNG(actual, width: width, height: height,
                         to: goldensDirectory.appendingPathComponent("\(name).actual.png"))
            Issue.record("\(name): \(String(format: "%.3f%%", fraction * 100)) of bytes differ (>3 levels); wrote .actual.png")
        }
    }
}

// MARK: - PNG IO (BGRA8, byteOrder32Little + premultipliedFirst)

private func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
    var data = pixels
    let image = data.withUnsafeMutableBytes { raw -> CGImage? in
        CGContext(
            data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )?.makeImage()
    }
    guard let image,
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw SnapshotError.encode(url.lastPathComponent) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw SnapshotError.encode(url.lastPathComponent)
    }
}

private func readPNG(_ url: URL) throws -> (pixels: [UInt8], width: Int, height: Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw SnapshotError.decode(url.lastPathComponent) }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (pixels, width, height)
}

private enum SnapshotError: Error {
    case encode(String)
    case decode(String)
}
