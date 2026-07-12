// MSL compiled at runtime for now (makeLibrary(source:) is ~ms, once per
// process); moving to an Xcode-built metallib is an option once the shader set
// stabilizes.
//
// Blending happens in GAMMA space: the target is .bgra8Unorm (NOT _srgb) with
// an sRGB layer colorspace, so encoded values blend directly. Mathematically
// "wrong", but exactly what CoreText/AppKit do — linear blending renders
// light-on-dark text visibly thin (P1 finding).
let documentShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct GlyphInstance {
    float2 origin;   // top-left, device pixels
    float2 size;     // device pixels
    float2 uvOrigin; // normalized atlas coords
    float2 uvSize;
    float4 color;    // sRGB-encoded, non-premultiplied
};

struct SolidInstance {
    float2 origin;
    float2 size;
    float4 color;
};

struct Varyings {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

static inline float4 project(float2 p, constant float2 &viewport) {
    return float4(p.x / viewport.x * 2.0 - 1.0,
                  1.0 - p.y / viewport.y * 2.0,
                  0.0, 1.0);
}

vertex Varyings glyph_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant GlyphInstance *instances [[buffer(0)]],
                             constant float2 &viewport [[buffer(1)]]) {
    GlyphInstance g = instances[iid];
    float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
    Varyings out;
    out.position = project(g.origin + corner * g.size, viewport);
    out.uv = g.uvOrigin + corner * g.uvSize;
    out.color = g.color;
    return out;
}

vertex Varyings solid_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant SolidInstance *instances [[buffer(0)]],
                             constant float2 &viewport [[buffer(1)]]) {
    SolidInstance s = instances[iid];
    float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
    Varyings out;
    out.position = project(s.origin + corner * s.size, viewport);
    out.uv = corner;
    out.color = s.color;
    return out;
}

// Quads sit on whole device pixels and atlases are read 1:1, so nearest
// sampling is exact and can never bleed neighboring glyphs.
constexpr sampler atlasSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

fragment float4 glyph_fragment_gray(Varyings in [[stage_in]],
                                    texture2d<float> atlas [[texture(0)]]) {
    float coverage = atlas.sample(atlasSampler, in.uv).r;
    float alpha = coverage * in.color.a;
    return float4(in.color.rgb * alpha, alpha); // premultiplied for (one, 1-srcAlpha)
}

fragment float4 glyph_fragment_color(Varyings in [[stage_in]],
                                     texture2d<float> atlas [[texture(0)]]) {
    // Color-emoji texels are already premultiplied by CoreGraphics.
    return atlas.sample(atlasSampler, in.uv) * in.color.a;
}

fragment float4 solid_fragment(Varyings in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}
"""
