#include <metal_stdlib>
using namespace metal;

struct SDRToHDRParameters {
    float yOffset;
    float yScale;
    float chromaOffset;
    float chromaScale;
    uint matrixKind;
    uint transferFunction;
    float gamma;
    uint outputMode;
    uint toneCurveRevision;
    float paperWhiteNits;
    float peakNits;
    float peakRatio;
    float highlightStrength;
    float contrastStrength;
    float saturationCompensation;
    float shadowProtection;
    float temporalAdaptation;
    float masteringHeadroom;
    float sceneShadowFloor;
    float sceneShadowTop;
    uint sceneStatisticsValid;
    uint sceneStatisticsReserved;
};

struct HDRDebugStats {
    atomic_uint inputLuminanceSum;
    atomic_uint inputLuminanceMax;
    atomic_uint outputLuminanceSum;
    atomic_uint outputLuminanceMax;
    atomic_uint highlightPixelCount;
    atomic_uint clippedPixelCount;
    atomic_uint pixelCount;
};

struct TemporalLumaStats {
    atomic_uint linearLuminanceSum;
    atomic_uint sampleCount;
    atomic_uint histogram[16];
};

constant float3 kBT709Luma = float3(0.2126, 0.7152, 0.0722);
constant float3 kBT2020Luma = float3(0.2627, 0.6780, 0.0593);
constant float3x3 kBT709ToBT2020 = float3x3(
    float3(0.6274040, 0.0690970, 0.0163916),
    float3(0.3292820, 0.9195400, 0.0880132),
    float3(0.0433136, 0.0113623, 0.8955950)
);

inline float smoothStepSafe(float edge0, float edge1, float value) {
    float denominator = max(edge1 - edge0, 1e-6f);
    float t = clamp((value - edge0) / denominator, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

inline float inverseBT709(float value) {
    value = max(value, 0.0f);
    return value < 0.081f ? value / 4.5f : pow((value + 0.099f) / 1.099f, 1.0f / 0.45f);
}

inline float inverseSRGB(float value) {
    value = max(value, 0.0f);
    return value <= 0.04045f ? value / 12.92f : pow((value + 0.055f) / 1.055f, 2.4f);
}

inline float inverseTransfer(float value, constant SDRToHDRParameters& p) {
    switch (p.transferFunction) {
        case 0: return inverseBT709(value);
        case 1: return inverseSRGB(value);
        case 2: return pow(max(value, 0.0f), max(p.gamma, 1e-4f));
        default: return max(value, 0.0f);
    }
}

inline float3 ycbcrToRGB(float y, float2 chroma, constant SDRToHDRParameters& p) {
    float cb = (chroma.x - p.chromaOffset) * p.chromaScale;
    float cr = (chroma.y - p.chromaOffset) * p.chromaScale;
    if (p.matrixKind == 1) {
        return float3(
            y + 1.402000f * cr,
            y - 0.344136f * cb - 0.714136f * cr,
            y + 1.772000f * cb
        );
    }
    if (p.matrixKind == 2) {
        return float3(
            y + 1.474600f * cr,
            y - 0.164553f * cb - 0.571353f * cr,
            y + 1.881400f * cb
        );
    }
    return float3(
        y + 1.574800f * cr,
        y - 0.187324f * cb - 0.468124f * cr,
        y + 1.855600f * cb
    );
}

inline float toneExpand(float luminance, constant SDRToHDRParameters& p) {
    float y = clamp(luminance, 0.0f, 1.0f);
    float shoulderStart = 0.68f - 0.20f * clamp(p.contrastStrength, 0.0f, 1.0f);
    float t = smoothStepSafe(shoulderStart, 1.0f, y);
    float shoulder = t * t * (3.0f - 2.0f * t);
    float strength = clamp(p.highlightStrength * p.temporalAdaptation, 0.0f, 1.0f);

    if (p.toneCurveRevision == 0) {
        float legacyShadowGate = smoothStepSafe(0.035f, 0.48f, y);
        float legacyProtection = 1.0f - clamp(p.shadowProtection, 0.0f, 1.0f) *
            (1.0f - legacyShadowGate);
        float legacyExpansion = (p.peakRatio - 1.0f) * strength * shoulder * y * legacyProtection;
        return clamp(y + max(legacyExpansion, 0.0f), y, p.peakRatio);
    }

    if (p.toneCurveRevision == 2) {
        // V4: shadow coordinates are derived from the source scene's causal
        // percentile estimator. If the first frame has no history yet, use a
        // conservative neutral band; the estimator updates the next frame.
        float shadowFloor = p.sceneStatisticsValid != 0 ? clamp(p.sceneShadowFloor, 0.001f, 0.20f) : 0.01f;
        float shadowTop = p.sceneStatisticsValid != 0
            ? max(p.sceneShadowTop, shadowFloor + 0.025f)
            : 0.1125f;
        shadowTop = min(shadowTop, 0.60f);
        float shadowWeight = 1.0f - smoothStepSafe(shadowFloor, shadowTop, y);
        float lowMidTransition = smoothStepSafe(shadowFloor, shadowTop, y);
        float lowMidExpansion = (p.peakRatio - 1.0f) * strength * 0.08f * lowMidTransition * y;
        float shoulderExpansion = (p.peakRatio - 1.0f) * strength * shoulder * y;
        float protection = 1.0f - 0.90f * clamp(p.shadowProtection, 0.0f, 1.0f) * shadowWeight;
        float expanded = y + (lowMidExpansion + shoulderExpansion) * protection;
        return clamp(expanded, y, p.peakRatio);
    }

    // V1/V2 multiplied highlight expansion by a shadow gate. The shoulder was
    // exactly zero below ~0.5 while that gate was already one above 0.48, so
    // shadowProtection was mathematically dead. V3 gives it an independent,
    // smooth shadow-band influence. Exact black and the deepest code values
    // retain unit gain; influence peaks in visible shadows and fades before
    // the highlight shoulder begins.
    float shadowPresence = smoothStepSafe(0.002f, 0.025f, y) *
        (1.0f - smoothStepSafe(0.12f, 0.48f, y));
    float shadowAttenuation = 0.18f * clamp(p.shadowProtection, 0.0f, 1.0f) * shadowPresence;
    float protectedBase = y * (1.0f - shadowAttenuation);
    float expansion = (p.peakRatio - 1.0f) * strength * shoulder * y;
    return clamp(protectedBase + max(expansion, 0.0f), 0.0f, p.peakRatio);
}

inline float3 gamutCompress(float3 rgb, float luminance, float peakRatio) {
    float safeLuminance = max(luminance, 0.0f);
    float minimum = min(rgb.x, min(rgb.y, rgb.z));
    float maximum = max(rgb.x, max(rgb.y, rgb.z));
    float chromaScale = 1.0f;
    if (minimum < 0.0f && safeLuminance > 0.0f) {
        chromaScale = min(chromaScale, safeLuminance / max(safeLuminance - minimum, 1e-6f));
    }
    if (maximum > peakRatio && maximum > safeLuminance) {
        chromaScale = min(chromaScale, max(peakRatio - safeLuminance, 0.0f) / max(maximum - safeLuminance, 1e-6f));
    }
    float3 neutral = float3(safeLuminance);
    return neutral + (rgb - neutral) * clamp(chromaScale, 0.0f, 1.0f);
}

inline float pqEncode(float normalizedLuminance) {
    constexpr float m1 = 2610.0f / 16384.0f;
    constexpr float m2 = 2523.0f / 32.0f;
    constexpr float c1 = 3424.0f / 4096.0f;
    constexpr float c2 = 2413.0f / 128.0f;
    constexpr float c3 = 2392.0f / 128.0f;
    float luminance = clamp(normalizedLuminance, 0.0f, 1.0f);
    float powered = pow(luminance, m1);
    return pow((c1 + c2 * powered) / (1.0f + c3 * powered), m2);
}

inline float pqDecode(float signal) {
    constexpr float m1 = 2610.0f / 16384.0f;
    constexpr float m2 = 2523.0f / 32.0f;
    constexpr float c1 = 3424.0f / 4096.0f;
    constexpr float c2 = 2413.0f / 128.0f;
    constexpr float c3 = 2392.0f / 128.0f;
    float powered = pow(clamp(signal, 0.0f, 1.0f), 1.0f / m2);
    return pow(max(powered - c1, 0.0f) / max(c2 - c3 * powered, 1e-6f), 1.0f / m1);
}

inline float3 linearizeSignal(float3 signal, constant SDRToHDRParameters& p) {
    signal = clamp(signal, 0.0f, 1.0f);
    return max(float3(
        inverseTransfer(signal.x, p),
        inverseTransfer(signal.y, p),
        inverseTransfer(signal.z, p)
    ), 0.0f);
}

inline void accumulateDebug(
    float3 inputSignal,
    float3 encodedOutput,
    constant SDRToHDRParameters& p,
    device HDRDebugStats* stats
) {
    float3 inputLinear = linearizeSignal(inputSignal, p);
    float inputLuminance = clamp(dot(inputLinear, kBT709Luma), 0.0f, 1.0f);
    float outputPeakRatio = p.outputMode == 0 ? min(p.peakRatio, p.masteringHeadroom) : p.peakRatio;
    float outputLuminance;
    if (p.outputMode == 0) {
        outputLuminance = clamp(dot(encodedOutput, kBT2020Luma) / max(outputPeakRatio, 1e-6f), 0.0f, 1.0f);
    } else {
        float3 normalizedLuminance = float3(
            pqDecode(encodedOutput.x),
            pqDecode(encodedOutput.y),
            pqDecode(encodedOutput.z)
        );
        outputLuminance = clamp(
            dot(normalizedLuminance, kBT2020Luma) * 10000.0f / max(p.paperWhiteNits * outputPeakRatio, 1e-6f),
            0.0f,
            1.0f
        );
    }
    // The 256 scale keeps the uint32 sums bounded through 4K frames while
    // retaining useful DEBUG-build trend information.
    uint inputQuantized = uint(inputLuminance * 256.0f + 0.5f);
    uint outputQuantized = uint(outputLuminance * 256.0f + 0.5f);
    atomic_fetch_add_explicit(&stats->inputLuminanceSum, inputQuantized, memory_order_relaxed);
    atomic_fetch_max_explicit(&stats->inputLuminanceMax, inputQuantized, memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->outputLuminanceSum, outputQuantized, memory_order_relaxed);
    atomic_fetch_max_explicit(&stats->outputLuminanceMax, outputQuantized, memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->highlightPixelCount, inputLuminance >= 0.75f ? 1u : 0u, memory_order_relaxed);
    float peakSignal = p.outputMode == 0 ? outputPeakRatio : pqEncode(p.peakNits / 10000.0f);
    atomic_fetch_add_explicit(&stats->clippedPixelCount, max(encodedOutput.x, max(encodedOutput.y, encodedOutput.z)) >= peakSignal - 0.0005f ? 1u : 0u, memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->pixelCount, 1u, memory_order_relaxed);
}

inline float3 transformSignalRGB(float3 signal, constant SDRToHDRParameters& p) {
    float3 linear = linearizeSignal(signal, p);
    float luminance = max(dot(linear, kBT709Luma), 0.0f);
    float expandedLuminance = toneExpand(luminance, p);
    float gain = expandedLuminance / max(luminance, 1e-6f);
    float3 expanded = linear * gain;
    float chromaReduction = clamp(
        p.saturationCompensation * smoothStepSafe(1.0f, max(1.001f, expandedLuminance), expandedLuminance) * 0.35f,
        0.0f,
        1.0f
    );
    expanded = mix(expanded, float3(expandedLuminance), chromaReduction);

    float3 bt2020 = kBT709ToBT2020 * expanded;
    float outputPeakRatio = p.outputMode == 0 ? min(p.peakRatio, p.masteringHeadroom) : p.peakRatio;
    bt2020 = gamutCompress(bt2020, dot(bt2020, kBT2020Luma), outputPeakRatio);
    bt2020 = clamp(bt2020, 0.0f, outputPeakRatio);

    if (p.outputMode == 0) {
        return bt2020;
    }
    return float3(
        pqEncode(bt2020.x * p.paperWhiteNits / 10000.0f),
        pqEncode(bt2020.y * p.paperWhiteNits / 10000.0f),
        pqEncode(bt2020.z * p.paperWhiteNits / 10000.0f)
    );
}

kernel void sdrNV12ToHDR(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    uint2 uvPosition = uint2(
        min(gid.x / 2, uvTexture.get_width() - 1),
        min(gid.y / 2, uvTexture.get_height() - 1)
    );
    float y = (yTexture.read(gid).r - p.yOffset) * p.yScale;
    float2 uv = uvTexture.read(uvPosition).rg;
    float3 signalRGB = ycbcrToRGB(y, uv, p);
    outputTexture.write(half4(float4(transformSignalRGB(signalRGB, p), 1.0f)), gid);
}

kernel void sdrBGRA8ToHDR(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    float4 input = inputTexture.read(gid);
    outputTexture.write(half4(float4(transformSignalRGB(input.rgb, p), 1.0f)), gid);
}

kernel void sdrNV12ToHDRDebug(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    device HDRDebugStats* stats [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    uint2 uvPosition = uint2(
        min(gid.x / 2, uvTexture.get_width() - 1),
        min(gid.y / 2, uvTexture.get_height() - 1)
    );
    float y = (yTexture.read(gid).r - p.yOffset) * p.yScale;
    float3 signalRGB = ycbcrToRGB(y, uvTexture.read(uvPosition).rg, p);
    float3 output = transformSignalRGB(signalRGB, p);
    outputTexture.write(half4(float4(output, 1.0f)), gid);
    accumulateDebug(signalRGB, output, p, stats);
}

kernel void sdrBGRA8ToHDRDebug(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    device HDRDebugStats* stats [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    float3 signalRGB = inputTexture.read(gid).rgb;
    float3 output = transformSignalRGB(signalRGB, p);
    outputTexture.write(half4(float4(output, 1.0f)), gid);
    accumulateDebug(signalRGB, output, p, stats);
}

// A 16x9 sparse proxy (144 reads) estimates source luminance asynchronously.
// It is independent of output resolution and does not read the HDR texture.
kernel void estimateNV12TemporalLuminance(
    texture2d<float, access::read> yTexture [[texture(0)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    device TemporalLumaStats* stats [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= 16 || gid.y >= 9) return;
    uint2 position = uint2(
        min((gid.x * yTexture.get_width() + yTexture.get_width() / 2) / 16, yTexture.get_width() - 1),
        min((gid.y * yTexture.get_height() + yTexture.get_height() / 2) / 9, yTexture.get_height() - 1)
    );
    float signal = clamp((yTexture.read(position).r - p.yOffset) * p.yScale, 0.0f, 1.0f);
    float linear = inverseTransfer(signal, p);
    atomic_fetch_add_explicit(&stats->linearLuminanceSum, uint(clamp(linear, 0.0f, 1.0f) * 65535.0f + 0.5f), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->sampleCount, 1u, memory_order_relaxed);
    if (p.toneCurveRevision == 2) {
        uint bin = min(uint(clamp(linear, 0.0f, 0.999999f) * 16.0f), 15u);
        atomic_fetch_add_explicit(&stats->histogram[bin], 1u, memory_order_relaxed);
    }
}

kernel void estimateBGRATemporalLuminance(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    device TemporalLumaStats* stats [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= 16 || gid.y >= 9) return;
    uint2 position = uint2(
        min((gid.x * inputTexture.get_width() + inputTexture.get_width() / 2) / 16, inputTexture.get_width() - 1),
        min((gid.y * inputTexture.get_height() + inputTexture.get_height() / 2) / 9, inputTexture.get_height() - 1)
    );
    float3 linear = linearizeSignal(inputTexture.read(position).rgb, p);
    float luminance = clamp(dot(linear, kBT709Luma), 0.0f, 1.0f);
    atomic_fetch_add_explicit(&stats->linearLuminanceSum, uint(luminance * 65535.0f + 0.5f), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->sampleCount, 1u, memory_order_relaxed);
    if (p.toneCurveRevision == 2) {
        uint bin = min(uint(luminance * 16.0f), 15u);
        atomic_fetch_add_explicit(&stats->histogram[bin], 1u, memory_order_relaxed);
    }
}
