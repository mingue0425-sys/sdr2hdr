#include <metal_stdlib>
using namespace metal;

struct PresentationUniforms {
    float4 destinationRect;
    uint orientation;
    uint fallbackToSDR;
    uint testPattern;
    uint hasTexture;
    float masteringHeadroom;
    float displayHeadroom;
};

struct PresentationVertexOut {
    float4 position [[position]];
    float2 uv;
};

constant float3x3 kBT2020ToBT709 = float3x3(
    float3(1.6604910, -0.1245510, -0.0181510),
    float3(-0.5876410, 1.1329000, -0.1005790),
    float3(-0.0728500, -0.0083490, 1.1187300)
);

vertex PresentationVertexOut presentationVertex(
    uint vertexID [[vertex_id]],
    constant PresentationUniforms& uniforms [[buffer(0)]]) {
    constexpr float2 positions[6] = {
        float2(0.0f, 0.0f), float2(1.0f, 0.0f), float2(1.0f, 1.0f),
        float2(0.0f, 0.0f), float2(1.0f, 1.0f), float2(0.0f, 1.0f)
    };
    float2 local = positions[vertexID];
    float2 display = uniforms.destinationRect.xy + local * uniforms.destinationRect.zw;
    PresentationVertexOut output;
    output.position = float4(display * 2.0f - 1.0f, 0.0f, 1.0f);
    output.uv = local;
    return output;
}

inline float2 orientedSourceUV(float2 displayUV, uint orientation) {
    // displayUV is top-left origin; Metal texture coordinates are also treated
    // as top-left for the CVPixelBuffer-derived texture. The vertex UV is
    // bottom-left, so flip Y before applying track orientation.
    float2 topLeftUV = float2(displayUV.x, 1.0f - displayUV.y);
    switch (orientation) {
        case 1: return float2(topLeftUV.y, 1.0f - topLeftUV.x);
        case 2: return float2(1.0f - topLeftUV.x, 1.0f - topLeftUV.y);
        case 3: return float2(1.0f - topLeftUV.y, topLeftUV.x);
        default: return topLeftUV;
    }
}

inline float mapEDRLuminance(float luminance, float masteringHeadroom, float displayHeadroom) {
    float y = max(luminance, 0.0f);
    float mastering = max(masteringHeadroom, 1.0f);
    float display = min(max(displayHeadroom, 1.0f), mastering);
    if (y <= 1.0f) return y;
    if (display <= 1.0f) return 1.0f;
    float bounded = min(y, mastering);
    if (display >= mastering - 1e-6f) return bounded;
    float sourceRange = mastering - 1.0f;
    float destinationRange = display - 1.0f;
    float x = bounded - 1.0f;
    float curvature = 1.0f / destinationRange - 1.0f / sourceRange;
    return min(1.0f + x / max(1.0f + curvature * x, 1e-6f), display);
}

inline float3 mapDirectEDR(float3 rgb, float masteringHeadroom, float displayHeadroom) {
    constexpr float3 kBT2020Luma = float3(0.2627f, 0.6780f, 0.0593f);
    float sourceLuminance = max(dot(rgb, kBT2020Luma), 0.0f);
    float mappedLuminance = mapEDRLuminance(sourceLuminance, masteringHeadroom, displayHeadroom);
    float3 mapped = sourceLuminance > 1e-6f ? rgb * (mappedLuminance / sourceLuminance) : float3(0.0f);

    // Compress only chroma that would exceed the physical component range.
    // The final clamp is a numerical safety guard; normal mapped samples reach
    // the bound through this luminance/chroma-preserving shoulder.
    float ceiling = min(max(displayHeadroom, 1.0f), max(masteringHeadroom, 1.0f));
    float3 neutral = float3(mappedLuminance);
    float3 chroma = mapped - neutral;
    float positiveChroma = max(chroma.x, max(chroma.y, chroma.z));
    if (positiveChroma > 0.0f && mappedLuminance + positiveChroma > ceiling) {
        float scale = max(ceiling - mappedLuminance, 0.0f) / positiveChroma;
        mapped = neutral + chroma * clamp(scale, 0.0f, 1.0f);
    }
    return clamp(mapped, 0.0f, ceiling);
}

fragment float4 presentationFragment(
    PresentationVertexOut in [[stage_in]],
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    sampler sourceSampler [[sampler(0)]],
    constant PresentationUniforms& uniforms [[buffer(0)]]) {
    float3 color;
    if (uniforms.testPattern != 0) {
        float x = in.uv.x;
        float value;
        if (x < 1.0f / 7.0f) value = 1.0f;
        else if (x < 2.0f / 7.0f) value = 1.1f;
        else if (x < 3.0f / 7.0f) value = 1.25f;
        else if (x < 4.0f / 7.0f) value = 1.5f;
        else if (x < 5.0f / 7.0f) value = 2.0f;
        else if (x < 6.0f / 7.0f) value = 3.0f;
        else value = 4.0f;
        color = float3(value);
    } else if (uniforms.hasTexture != 0) {
        float2 uv = orientedSourceUV(in.uv, uniforms.orientation);
        color = sourceTexture.sample(sourceSampler, uv).rgb;
    } else {
        color = float3(0.0f);
    }

    if (uniforms.fallbackToSDR != 0) {
        // Only the explicit SDR fallback is allowed to clamp. EDR path keeps
        // values above 1.0 all the way to the RGBA16Float drawable.
        color = clamp(kBT2020ToBT709 * color, 0.0f, 1.0f);
    } else {
        color = mapDirectEDR(color, uniforms.masteringHeadroom, uniforms.displayHeadroom);
    }
    return float4(color, 1.0f);
}
