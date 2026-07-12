# P1 spike findings — text on the GPU

Verified on Apple M1 Max, macOS 26.5, 2026-07-12. Everything below was measured
with `make spike-dump` (PNGs + stats in `out/`); the windowed side-by-side is
`make spike`.

## What the spike retired

**Custom Metal text can match AppKit/CoreText rendering.** Mean luminance bias
vs a CoreText reference render of the identical shaped lines: **+1.4** (dark
theme) / **+0.9** (light theme) on a 0–255 scale. Residual diffs are symmetric
edge fringes from subpixel-bucket quantization, invisible at reading distance.

## Decisions confirmed for VWText/VWRender (P2)

1. **Gamma-space blending on `.bgra8Unorm`** (layer colorspace sRGB) is correct
   for white-on-dark text: near-parity out of the box. Linear blending is not
   needed and would break parity.
2. **Dual-polarity glyph masks are required** — the one discovery that wasn't in
   the plan. CoreGraphics adjusts text coverage by polarity: compositing
   dark-on-light text from a white-on-black mask renders it **14.5 levels too
   dark/fat**. Fix: when text is darker than the background, rasterize the
   glyph black-on-white and invert into coverage. `darkOnLight` is part of the
   atlas key; a theme flip lazily re-rasterizes (still no re-layout).
3. **Stem darkening on**: `setShouldSmoothFonts(true)` in atlas contexts,
   matching AppKit's default.
4. **4 subpixel x-buckets suffice**: total ink varies **0.01%** across
   fractional x offsets (budget was <2%). Baselines rounded to whole pixels in
   y; x keeps its fraction.
5. **Color emoji**: separate bgra8 pages, premultiplied from CG, whole-pixel
   placement, single bucket. ZWJ families, flags, skin tones all resolve to
   single glyphs via CoreText shaping — no special handling.
6. **Retina flush**: atlas `flush(scale:)` + reshape re-rasterizes cleanly
   (verified 2x → 1x).
7. **Nearest sampling + integral quad placement**: exact atlas reads, no
   bleeding, 1px padding is enough.

## Numbers for P2 budgeting

- Sample doc (10 mixed lines, 273 glyphs incl. emoji): **first frame
  (shape + rasterize + encode + GPU wait) ≈ 13ms cold**, ~4–5ms with a second
  atlas already warm. Steady-state frames re-encode without rasterization.
- Atlas footprint for the whole sample at 2x: **1 gray + 1 color page** (1024²
  each — 1MB + 4MB).
- Draw calls: 2 (one per page in use).

## Carry-over cautions

- CTRun attribute extraction must use `CFDictionaryGetValue` +
  `unsafeBitCast` (toll-free bridging); dictionary casts are not reliable for
  CF types.
- The MSL `GlyphInstance` struct layout is asserted against
  `MemoryLayout<Instance>.stride == 48` at pipeline init — keep the assert.
- Emoji quads diff visibly against a true-subpixel reference (≤0.5px shift);
  acceptable, but don't "fix" it by giving color glyphs buckets — page memory
  quadruples for no visible gain.
