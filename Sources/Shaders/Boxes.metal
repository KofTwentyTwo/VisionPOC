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

struct LineUniforms {
    float4 endpoints;  // xy = start in NDC, zw = end in NDC
    float4 color;
    float4 params;     // x = thickness in NDC units; y = soft-edge falloff width (0 = sharp); z = dot mode (0=line, 1=dot); w reserved
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

// -----------------------------------------------------------------------------
// Line vertex shader.
//
// Emits a 6-vertex triangle pair representing a rotated rectangle of the
// requested thickness, oriented along the direction (end - start). UV.x is
// the normalized 0..1 distance along the line; UV.y is the signed
// perpendicular offset, scaled so |uv.y| < 1.0 stays inside the line. The
// fragment uses uv.y for soft-edge antialiasing.
//
// In dot mode (params.z > 0.5), the start endpoint is rendered as a circular
// dot of radius = thickness, ignoring `end`. Useful for joint markers.
// -----------------------------------------------------------------------------
vertex QuadVaryings line_vertex(uint vid [[vertex_id]],
                                constant LineUniforms& u [[buffer(0)]]) {
    float2 start = u.endpoints.xy;
    float2 end   = u.endpoints.zw;
    float thick  = max(u.params.x, 0.0005);

    if (u.params.z > 0.5) {
        // Dot mode: emit a `2*thick`-wide square around `start`.
        float2 unit[6] = {
            float2(-1, -1), float2( 1, -1), float2(-1,  1),
            float2( 1, -1), float2( 1,  1), float2(-1,  1)
        };
        float2 corner = unit[vid];
        float2 ndc = start + corner * thick;
        QuadVaryings out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = corner;  // unit-circle test space in [-1,1]^2
        return out;
    }

    float2 dir = end - start;
    float lengthDir = max(length(dir), 1e-5);
    float2 forward = dir / lengthDir;
    float2 perp = float2(-forward.y, forward.x) * thick;

    // Order: bottom-left, bottom-right, top-left | bottom-right, top-right, top-left
    // along the line direction: start side is "bottom", end side is "top".
    float2 sBL = start - perp;
    float2 sTR = start + perp;
    float2 eBL = end   - perp;
    float2 eTR = end   + perp;

    float2 positions[6] = { sBL, eBL, sTR, eBL, eTR, sTR };
    float2 uvs[6] = {
        float2(0, -1), float2(1, -1), float2(0,  1),
        float2(1, -1), float2(1,  1), float2(0,  1)
    };

    QuadVaryings out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

// -----------------------------------------------------------------------------
// Line fragment shader.
//
// In line mode: uv.y is signed perpendicular offset (-1..1 spans the line's
// full thickness). A smoothstep on |uv.y| produces a feathered edge so the
// line reads as a soft stroke rather than a hard rectangle.
//
// In dot mode: uv is the unit-circle space; fragments outside the unit
// circle are discarded, producing a filled disk.
// -----------------------------------------------------------------------------
fragment float4 line_fragment(QuadVaryings in [[stage_in]],
                              constant LineUniforms& u [[buffer(0)]]) {
    if (u.params.z > 0.5) {
        float r = length(in.uv);
        if (r > 1.0) {
            discard_fragment();
        }
        // Soft edge on the disk for a sub-pixel-clean look.
        float alpha = smoothstep(1.0, 0.85, r);
        return float4(u.color.rgb, u.color.a * alpha);
    }

    float falloff = max(u.params.y, 0.05);
    float a = smoothstep(1.0, 1.0 - falloff, abs(in.uv.y));
    return float4(u.color.rgb, u.color.a * a);
}
