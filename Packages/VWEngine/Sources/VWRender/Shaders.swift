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

struct PillInstance {
    float2 origin;   // top-left, device pixels
    float2 size;
    float4 color;    // sRGB-encoded, non-premultiplied
    float radius;    // corner radius, device pixels
    float stroke;    // 0 = filled; >0 = inside border of this width
    float _pad1;
    float _pad2;
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

// Diagram rasters draw at their display size, which need not match the
// texture 1:1 (width caps, zoom drift) — linear filtering absorbs the
// resample. Separate sampler on purpose: atlasSampler's nearest is
// load-bearing for glyph exactness.
constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);

fragment float4 image_fragment(Varyings in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    // Raster texels are premultiplied BGRA straight from CoreGraphics.
    return atlas.sample(imageSampler, in.uv) * in.color.a;
}

fragment float4 solid_fragment(Varyings in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

// Rounded-rect pills (the overlay scrollbar): analytic SDF coverage with a
// one-pixel anti-aliased edge — no textures, resolution-independent.
struct PillVaryings {
    float4 position [[position]];
    float2 local;     // fragment position within the quad, device pixels
    float2 halfSize;
    float radius;
    float stroke;
    float4 color;
};

vertex PillVaryings pill_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant PillInstance *instances [[buffer(0)]],
                                constant float2 &viewport [[buffer(1)]]) {
    PillInstance p = instances[iid];
    float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
    PillVaryings out;
    out.position = project(p.origin + corner * p.size, viewport);
    out.local = corner * p.size;
    out.halfSize = p.size * 0.5;
    out.radius = min(p.radius, min(p.size.x, p.size.y) * 0.5);
    out.stroke = p.stroke;
    out.color = p.color;
    return out;
}

fragment float4 pill_fragment(PillVaryings in [[stage_in]]) {
    float2 q = abs(in.local - in.halfSize) - (in.halfSize - in.radius);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - in.radius;
    float coverage = saturate(0.5 - d);
    if (in.stroke > 0.0) {
        // Inside border: subtract the interior beyond the stroke width.
        coverage -= saturate(0.5 - (d + in.stroke));
    }
    float alpha = coverage * in.color.a;
    return float4(in.color.rgb * alpha, alpha);
}
"""
