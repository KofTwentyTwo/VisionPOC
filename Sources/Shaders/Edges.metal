#include <metal_stdlib>
using namespace metal;

struct QuadVaryings {
    float4 position [[position]];
    float2 uv;
};

// -----------------------------------------------------------------------------
// Threshold compute kernel.
//
// inTex is the output of MPSImageSobel: a BGRA texture where R holds the
// gradient magnitude (G/B carry similar info). We treat R as the magnitude
// signal, compare to a host-supplied threshold, and write pure white or pure
// black to outTex. Skips writes if gid is outside outTex bounds.
// -----------------------------------------------------------------------------
kernel void edge_threshold(texture2d<float, access::read>  inTex     [[texture(0)]],
                           texture2d<float, access::write> outTex    [[texture(1)]],
                           constant float&                 threshold [[buffer(0)]],
                           uint2                           gid       [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }
    float4 src = inTex.read(gid);
    // MPSImageSobel writes the gradient magnitude into the R channel; using
    // luma here also works defensively in case the input format differs.
    float mag = max(src.r, dot(src.rgb, float3(0.299, 0.587, 0.114)));
    float4 outColor = (mag > threshold) ? float4(1.0, 1.0, 1.0, 1.0)
                                        : float4(0.0, 0.0, 0.0, 1.0);
    outTex.write(outColor, gid);
}

// -----------------------------------------------------------------------------
// Edge display fragment.
//
// Samples the thresholded edge texture and tints the result very slightly cyan
// against a pure-black background. Uses a NEAREST sampler so edge pixels stay
// crisp under arbitrary viewport scaling.
// -----------------------------------------------------------------------------
fragment float4 edges_fragment(QuadVaryings in [[stage_in]],
                               texture2d<float> edgeTex [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest,
                        address::clamp_to_edge);
    float4 sampled = edgeTex.sample(s, in.uv);
    float3 rgb = sampled.rgb * float3(0.85, 1.0, 1.0);
    return float4(rgb, 1.0);
}
