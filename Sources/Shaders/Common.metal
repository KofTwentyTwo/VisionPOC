#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------------
// VisionPOC shared shader types.
//
// IMPORTANT: The field order of every uniform struct here is a hard contract
// with the Swift renderer. Do not reorder. See docs/.../visionpoc-design.md.
// -----------------------------------------------------------------------------

struct QuadVaryings {
    float4 position [[position]];
    float2 uv;
};

struct JarvisUniforms {
    float    time;
    float2   resolution;
    float    scanlineDensity;
    float    hexGridScale;
    float    beamPhase;
    float4   tintColor;
};

struct BoxUniforms {
    float4 rect;   // xy = origin in NDC ([-1,1]), zw = size in NDC
    float4 color;
};

// -----------------------------------------------------------------------------
// Fullscreen quad vertex shader.
//
// Six-vertex triangle pair covering NDC [-1,1]^2. UVs are emitted with v
// flipped (origin top-left) so camera textures stored origin-top-left sample
// upright when displayed.
// -----------------------------------------------------------------------------
vertex QuadVaryings quad_vertex(uint vid [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0),
        float2(-1.0,  1.0)
    };
    // v flipped: origin top-left for camera textures.
    float2 uvs[6] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(1.0, 0.0),
        float2(0.0, 0.0)
    };

    QuadVaryings out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

// -----------------------------------------------------------------------------
// HUD text fragment.
//
// Samples a BGRA premultiplied glyph texture and multiplies by a tint passed
// in constant buffer 0. Linear filtering, clamp-to-edge.
// -----------------------------------------------------------------------------
fragment float4 text_fragment(QuadVaryings in [[stage_in]],
                              texture2d<float> glyphTex [[texture(0)]],
                              constant float4& tint [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear,
                        address::clamp_to_edge);
    // The TextRasterizer renders glyphs via a y-flipped CGContext so the
    // bitmap's memory row 0 is the BOTTOM of the rendered text (CoreText y-up
    // convention). quad_vertex emits uv with v=0 at the top of the screen, so
    // we'd sample top-of-screen at memory-row-0 = bottom-of-text → upside
    // down. Flip v on the sampling side to put the top of the text at the top
    // of the quad.
    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    float4 sampled = glyphTex.sample(s, uv);
    return sampled * tint;
}
