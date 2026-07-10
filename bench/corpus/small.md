# vw benchmark: small

A small, hand-curated document — roughly the size of a short LLM answer. It exercises
every basic construct once so the small-file path renders *all* block kinds, not just
paragraphs.

## Why speed is the product

Markdown is increasingly what LLMs produce, and reading it should feel **instant**.
The budget for this file is `< 400ms` cold and `< 100ms` warm, measured from process
start to pixels on glass — not to `applicationDidFinishLaunching`, which is where most
apps stop counting.

### The pipeline

1. Parse bytes into a compact IR with [swift-markdown](https://github.com/swiftlang/swift-markdown)
2. Flatten nested structure into a linear block array
3. Lay out only the viewport, estimate the rest
4. Rasterize glyphs into an atlas, draw instanced quads

> The fastest code is the code that doesn't run: estimates plus scroll anchoring mean
> a 100MB document costs the same first frame as this file.

## A little code

```swift
let clock = LaunchClock.shared
let trace = PerfReporter.shared.beginTrace(label: url.lastPathComponent)
trace.mark("read")
```

## A little data

| Phase | Budget | Owner |
| :--- | ---: | :--- |
| pre-main | 50ms | dyld |
| parse | 10ms | VWParse |
| layout | 5ms | VWLayout |
| present | 8ms | VWRender |

- [x] blank-window baseline recorded
- [x] perf harness end-to-end
- [ ] first styled pixels (P2)
- [ ] 120Hz scroll on 100MB (P3)

---

*That's the whole file — small on purpose.*
