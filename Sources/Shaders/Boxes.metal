#include <metal_stdlib>
using namespace metal;

struct QuadVaryings {
    float4 position [[position]];
    float2 uv;
};

struct BoxUniforms {
    float4 rect;    // xy = origin in NDC ([-1,1]), zw = size in NDC
    float4 color;
    float4 params;  // x = mode (0=hollow stroke, 1=solid fill), y/z/w reserved
};

// -----------------------------------------------------------------------------
// Box vertex shader.
//
// Emits a 6-vertex triangle pair sized by u.rect.zw and positioned at
// u.rect.xy in NDC. UV is the unit-square parametric coordinate (0..1) inside
// the rect, used by the fragment to identify the stroke band.
//
// The renderer can either:
//   (a) submit one draw per stroke edge (four thin rects per detection), in
//       which case the fragment is just a solid fill — u.rect.zw is the thin
//       rect's full size, no stroke math is needed; or
//   (b) submit one draw per detection with the full bounding rect, letting
//       box_fragment discard the interior to produce a hollow outline.
//
// box_fragment supports option (b); for option (a) the caller can ignore the
// hollow-mask logic by setting u.rect.zw small enough that the entire quad
// falls inside the stroke band (it will, because uv spans 0..1 across the
// thin rect and the band is thicker than that on degenerate sizes).
// -----------------------------------------------------------------------------
vertex QuadVaryings box_vertex(uint vid [[vertex_id]],
                               constant BoxUniforms& u [[buffer(0)]]) {
    // Unit-quad corners, two triangles, six vertices.
    float2 corners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };
    float2 unit = corners[vid];
    float2 ndc  = u.rect.xy + unit * u.rect.zw;

    QuadVaryings out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = unit;
    return out;
}

// -----------------------------------------------------------------------------
// Box fragment shader.
//
// Hollow-rect outline: discards fragments whose UV is well inside the rect,
// leaving a stroke band along all four edges. Stroke thickness is computed in
// UV space from the rect's NDC size so the visual thickness stays roughly
// constant across box sizes.
//
// If the caller is using option (a) above (four thin rects per box, drawn as
// solid fills), the inside-test will simply always fail (uv stays inside the
// degenerate stroke band on a thin rect) and the full color is returned.
// -----------------------------------------------------------------------------
fragment float4 box_fragment(QuadVaryings in [[stage_in]],
                             constant BoxUniforms& u [[buffer(0)]]) {
    // Mode 1: solid fill — return the color directly (used by HUD corner brackets).
    if (u.params.x > 0.5) {
        return u.color;
    }

    // Mode 0: hollow stroke — discard fragments well inside the rect, leaving
    // a stroke band along all four edges (used by detection bounding boxes).
    float2 sizeNDC = abs(u.rect.zw);
    float2 thick = clamp(float2(0.012, 0.012) / max(sizeNDC, float2(0.0001)),
                         float2(0.02, 0.02), float2(0.5, 0.5));

    bool insideX = (in.uv.x > thick.x) && (in.uv.x < 1.0 - thick.x);
    bool insideY = (in.uv.y > thick.y) && (in.uv.y < 1.0 - thick.y);
    if (insideX && insideY) {
        discard_fragment();
    }
    return u.color;
}
