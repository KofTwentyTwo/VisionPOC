#include <metal_stdlib>
using namespace metal;

// Local redeclarations (see Live.metal for rationale).
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

// -----------------------------------------------------------------------------
// Iron Man / Jarvis HUD stylization — fragment-only.
//
// Layered on top of a passthrough camera sample:
//   1. luma -> cyan tint (with a small lift on the blacks)
//   2. scanlines modulating brightness
//   3. subtle hex-grid edges multiplied in
//   4. horizontal scanning beam (bright bar sweeping vertically)
//   5. vignette
//   6. faint chromatic edge ghost (sample R/B at small horizontal offsets)
// -----------------------------------------------------------------------------
fragment float4 jarvis_fragment(QuadVaryings in [[stage_in]],
                                texture2d<float> camTex [[texture(0)]],
                                constant JarvisUniforms& u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear,
                        address::clamp_to_edge);

    // --- base passthrough sample ---
    float4 srcColor = camTex.sample(s, in.uv);
    float3 src      = srcColor.rgb;

    // --- 1. luma -> cyan tint, with black lift ---
    float luma = dot(src, float3(0.299, 0.587, 0.114));
    // Lift blacks slightly so dark regions still carry some tint.
    float lifted = mix(0.15, 1.0, luma);
    float3 base = lifted * u.tintColor.rgb;

    // --- 2. scanlines ---
    float scan = 0.5 + 0.5 * sin(in.uv.y * u.scanlineDensity + u.time * 6.0);
    float scanMod = mix(0.85, 1.0, scan);
    base *= scanMod;

    // --- 3. hex grid overlay (subtle thin edges) ---
    // Axial-style coordinate squish; identical pattern shape used in MetalPOC.
    float2 h = in.uv * u.hexGridScale;
    h.x *= 1.1547005;                       // 2/sqrt(3)
    h.y += fmod(floor(h.x), 2.0) * 0.5;
    float2 hf = fract(h) - 0.5;
    float hexDist = max(abs(hf.x),
                        max(abs(hf.y) + abs(hf.x) * 0.5,
                            abs(hf.y) * 1.1547));
    float hexEdge = smoothstep(0.45, 0.49, hexDist) -
                    smoothstep(0.49, 0.50, hexDist);
    base += u.tintColor.rgb * hexEdge * 0.10;

    // --- 4. scanning beam ---
    float beamY    = u.beamPhase;
    float beamMask = smoothstep(0.02, 0.0, abs(in.uv.y - beamY));
    base += beamMask * 0.25;
    base += beamMask * float3(0.2, 0.4, 0.45);

    // --- 5. vignette ---
    float v = smoothstep(0.95, 0.4, length(in.uv - 0.5));
    base *= mix(0.65, 1.0, v);

    // --- 6. chromatic edge ghost ---
    float r2 = camTex.sample(s, in.uv + float2( 0.0015, 0.0)).r;
    float b2 = camTex.sample(s, in.uv - float2( 0.0015, 0.0)).b;
    float lumaR = dot(float3(r2, src.g, src.b), float3(0.299, 0.587, 0.114));
    float lumaB = dot(float3(src.r, src.g, b2), float3(0.299, 0.587, 0.114));
    float3 ghost = float3(lumaR, luma, lumaB) * u.tintColor.rgb;
    base = mix(base, base * 0.7 + ghost * 0.3, 0.30);

    return float4(base, 1.0);
}
