#include <metal_stdlib>
using namespace metal;

// QuadVaryings is also declared in Common.metal. Each .metal file compiles as
// its own translation unit, so redeclaring here is safe and keeps each shader
// readable in isolation.
struct QuadVaryings {
    float4 position [[position]];
    float2 uv;
};

// -----------------------------------------------------------------------------
// Live passthrough fragment.
//
// Samples the camera texture and returns it unmodified. Linear sampler with
// clamp-to-edge — the UVs come from quad_vertex (origin top-left) so the
// camera frame displays upright.
// -----------------------------------------------------------------------------
fragment float4 live_fragment(QuadVaryings in [[stage_in]],
                              texture2d<float> camTex [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear,
                        address::clamp_to_edge);
    return camTex.sample(s, in.uv);
}
