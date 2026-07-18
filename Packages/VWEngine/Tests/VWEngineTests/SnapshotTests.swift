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

| feature | status | latency budget |
| :------ | :----: | -------------: |
| parse into compact IR with spans preserved | **done** | 10ms |
| viewport-lazy layout | done | 5ms |
| `vw` CLI | done | 50ms |

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

private let goldenMermaidSource = """
graph TD
    A[Start] --> B{Build?}
    B -->|yes| C[Ship it]
    B -->|no| D[Fix first]
"""

private let goldenMermaidMarkdown = """
### Mermaid

Paragraph before the fence — the pending state shows a loading skeleton.

```mermaid
\(goldenMermaidSource)
```

Paragraph after the fence proves flow resumes below the raster.
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

    /// A mermaid fence before the session swap: the pending-diagram loading
    /// skeleton (code-block chrome + ghost nodes, no source text).
    @Test @MainActor func goldenMermaidPlaceholder() throws {
        try assertSnapshot(
            name: "golden-mermaid-placeholder-dark", theme: .dark,
            markdown: goldenMermaidMarkdown
        )
    }

    /// After the session swap: `kind == .diagram` + DiagramInfo (the same
    /// transform applyDiagram performs), raster resolved through the
    /// diagramTextures store and drawn as a textured quad. The stand-in
    /// raster is programmatic fills — no text — so the golden is
    /// toolchain-stable.
    @Test @MainActor func goldenMermaidSwapped() throws {
        let naturalSize = CGSize(width: 300, height: 180)
        let imageKey = diagramImageKey(source: goldenMermaidSource, isDark: true, pixelScale: 2)
        try assertSnapshot(
            name: "golden-mermaid-swapped-dark", theme: .dark,
            markdown: goldenMermaidMarkdown,
            transform: { document in
                for index in document.blocks.indices
                where isMermaidLanguage(document.blocks[index].codeLanguage) {
                    document.blocks[index].kind = .diagram
                    document.blocks[index].diagram = DiagramInfo(
                        imageKey: imageKey, naturalSizePts: naturalSize
                    )
                }
            },
            diagramTextures: { device in
                // 2× the natural point size: the quad samples 1:1 at scale 2.
                [imageKey: try makeDiagramTexture(device: device, width: 600, height: 360)]
            }
        )
    }

    @MainActor
    private func assertSnapshot(
        name: String, theme: Theme,
        markdown: String = goldenMarkdown,
        transform: ((inout FlatDocument) -> Void)? = nil,
        diagramTextures: ((MTLDevice) throws -> [UInt64: MTLTexture])? = nil
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
        // Built against the renderer's device — textures aren't portable
        // across MTLDevice instances.
        let textures = try diagramTextures?(renderer.device) ?? [:]
        let texture = renderer.renderOffscreen(
            layout: layout, theme: theme,
            originPts: CGPoint(x: insetPts, y: insetPts),
            scale: scale, diagramTextures: textures, width: width, height: height
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

// MARK: - Deterministic diagram raster

/// Diagram stand-in: two "node" panels, an "edge" bar, and a stepped color
/// strip — axis-aligned opaque fills on integral pixel edges with AA off, so
/// the bytes are identical across toolchains (unlike anything CoreText
/// touches). Drawn in the renderer's texel format (premultipliedFirst +
/// byteOrder32Little sRGB) and uploaded as .bgra8Unorm, the same recipe the
/// viewer's texture upload uses.
private func makeDiagramTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw SnapshotError.encode("diagram-texture") }
        context.setShouldAntialias(false)
        // 20×20 unit grid keeps every edge on a whole pixel for the golden's
        // 600×360 (units of 30×18).
        let ux = CGFloat(width / 20), uy = CGFloat(height / 20)
        context.setFillColor(CGColor(srgbRed: 0.13, green: 0.15, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setFillColor(CGColor(srgbRed: 0.36, green: 0.62, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: ux * 2, y: uy * 11, width: ux * 6, height: uy * 6))
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.61, blue: 0.30, alpha: 1))
        context.fill(CGRect(x: ux * 12, y: uy * 3, width: ux * 6, height: uy * 6))
        context.setFillColor(CGColor(srgbRed: 0.80, green: 0.82, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: ux * 8, y: uy * 13, width: ux * 4, height: uy))
        for band in 0..<10 {
            let t = CGFloat(band) / 9
            context.setFillColor(CGColor(srgbRed: 0.2 + 0.6 * t, green: 0.9 - 0.5 * t, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: ux * CGFloat(band) * 2, y: 0, width: ux * 2, height: uy))
        }
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
    )
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw SnapshotError.encode("diagram-texture")
    }
    pixels.withUnsafeBytes { raw in
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: raw.baseAddress!, bytesPerRow: width * 4
        )
    }
    return texture
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
