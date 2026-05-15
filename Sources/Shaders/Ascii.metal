#include <metal_stdlib>
using namespace metal;

struct QuadVaryings {
    float4 position [[position]];
    float2 uv;
};

struct AsciiUniforms {
    float2 gridSize;        // number of character cells across x, y
    float  atlasCharCount;  // number of glyphs in the horizontal atlas
    float  pad0;
    float4 tintColor;       // RGB tint applied to the glyph alpha
};

// -----------------------------------------------------------------------------
// ASCII art fragment.
//
// Quantizes the source image into a grid of character cells. For each cell:
//   1. Sample the source at the cell's center to get a representative color.
//   2. Compute luminance and pick a glyph index from the dark-to-bright atlas.
//   3. Sample the atlas at the appropriate sub-region using the within-cell UV.
//
// The atlas is a horizontal strip of N monospace glyphs rasterized into a
// single bitmap (` .:-=+*#%@` from dark to bright by default). The fragment
// composes one ASCII glyph per grid cell, tinted with `tintColor`.
//
// Source UV convention matches quad_vertex: v=0 at top of texture (origin
// top-left, the way the camera frames are stored).
// -----------------------------------------------------------------------------
fragment float4 ascii_fragment(QuadVaryings in [[stage_in]],
                               texture2d<float> sourceTex [[texture(0)]],
                               texture2d<float> atlasTex  [[texture(1)]],
                               constant AsciiUniforms& u  [[buffer(0)]]) {
    constexpr sampler srcSampler(coord::normalized, filter::linear,
                                 address::clamp_to_edge);
    constexpr sampler atlasSampler(coord::normalized, filter::linear,
                                   address::clamp_to_edge);

    float2 grid = max(u.gridSize, float2(1.0, 1.0));
    float2 cell = floor(in.uv * grid);
    float2 within = fract(in.uv * grid);

    // Sample source at the center of this cell so all fragments within a cell
    // resolve to the same character.
    float2 cellCenter = (cell + float2(0.5, 0.5)) / grid;
    float4 srcSample = sourceTex.sample(srcSampler, cellCenter);
    float luma = dot(srcSample.rgb, float3(0.299, 0.587, 0.114));

    // Map luma to a glyph index. The atlas runs dark-to-bright left-to-right,
    // so brighter source regions get denser glyphs.
    float charCount = max(u.atlasCharCount, 1.0);
    float idxF = clamp(luma, 0.0, 0.9999) * charCount;
    float idx  = floor(idxF);

    // Atlas UV: locate the chosen glyph slot, then use within-cell UV inside
    // that slot. Vertical UV needs a flip for the same reason text_fragment
    // does — the atlas is rasterized in the y-flipped CGContext convention.
    float2 atlasUV = float2((idx + within.x) / charCount, 1.0 - within.y);
    float4 glyph = atlasTex.sample(atlasSampler, atlasUV);

    // The atlas glyph is white-on-transparent (premultiplied BGRA). Use its
    // alpha as the glyph mask and tint to the requested color.
    float mask = glyph.a;
    return float4(u.tintColor.rgb * mask, 1.0);
}
