// VWRender — glyph atlas + Metal pipeline (lands in P1/P2).
//
// GlyphAtlas: 1024² pages, r8 alpha (grayscale AA) + rgba8 color-emoji pages,
// 4 subpixel x-buckets, shelf packing, generational eviction, full flush on
// backingScaleFactor change. DisplayList: solid quads below text / glyph quads
// bucketed by page / solids above. Gamma-space blending on .bgra8Unorm to match
// platform text weight.
