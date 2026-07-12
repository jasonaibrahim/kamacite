// MSL as a string: the spike compiles shaders at runtime so a bare `swift run`
// works. The real engine (VWRender, P2) moves these into .metal files built by
// Xcode into a metallib.
//
// Blending happens in gamma space: the drawable is .bgra8Unorm (NOT _srgb) with
// an sRGB layer colorspace, so encoded values blend directly. Mathematically
// "wrong", but it is exactly what CoreText/AppKit do — linear blending renders
// light-on-dark text visibly thin.
let glyphShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct GlyphInstance {
    float2 origin;   // top-left, device pixels
    float2 size;     // device pixels
    float2 uvOrigin; // normalized atlas coords
    float2 uvSize;
    float4 color;    // sRGB-encoded, non-premultiplied
};

struct GlyphVaryings {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex GlyphVaryings glyph_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  constant GlyphInstance *instances [[buffer(0)]],
                                  constant float2 &viewport [[buffer(1)]]) {
    GlyphInstance g = instances[iid];
    float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
    float2 p = g.origin + corner * g.size;
    GlyphVaryings out;
    out.position = float4(p.x / viewport.x * 2.0 - 1.0,
                          1.0 - p.y / viewport.y * 2.0,
                          0.0, 1.0);
    out.uv = g.uvOrigin + corner * g.uvSize;
    out.color = g.color;
    return out;
}

// Quads are placed on whole device pixels and atlases are read 1:1, so nearest
// sampling is exact and can never bleed neighboring glyphs.
constexpr sampler atlasSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

fragment float4 glyph_fragment_gray(GlyphVaryings in [[stage_in]],
                                    texture2d<float> atlas [[texture(0)]]) {
    float coverage = atlas.sample(atlasSampler, in.uv).r;
    float alpha = coverage * in.color.a;
    return float4(in.color.rgb * alpha, alpha); // premultiplied for (one, 1-srcAlpha)
}

fragment float4 glyph_fragment_color(GlyphVaryings in [[stage_in]],
                                     texture2d<float> atlas [[texture(0)]]) {
    // Color-emoji texels are already premultiplied by CoreGraphics.
    return atlas.sample(atlasSampler, in.uv) * in.color.a;
}
"""
