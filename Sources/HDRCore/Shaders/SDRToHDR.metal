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
    float bt1886BlackLuminance;
    float bt1886WhiteLuminance;
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
    uint histogramStrategy;
    uint sceneProxyWidth;
    uint sceneProxyHeight;
    uint sceneHistogramBinCount;
    uint sceneLinear16HistogramBinCount;
    float sceneInputMinimum;
    float sceneInputMaximum;
    float sceneHistogramUpperExclusive;
    float sceneHistogramLogMinimumExponent;
    float sceneHistogramLogMaximumExponent;
    float sceneShadowDenseBreakpoint;
    uint sceneShadowDenseLowerBinCount;
    float sceneShadowDenseUpperSpan;
    float sceneQuantizationMaximum;
    float sceneQuantizationRounding;
    float sceneP01;
    float sceneP05;
    float sceneP50;
    float sceneP90;
    float sceneP99;
    float diagnosticROIX;
    float diagnosticROIY;
    float diagnosticROIWidth;
    float diagnosticROIHeight;
    uint diagnosticROIEnabled;
    float developmentLowMidFadePosition;
    float developmentLowMidStrength;
    uint developmentExpansionController;
    float developmentExpansionMinimumBudget;
    float developmentExpansionHighlightLow;
    float developmentExpansionHighlightHigh;
    float developmentExpansionRangeLow;
    float developmentExpansionRangeHigh;
    float developmentExpansionMidtoneLow;
    float developmentExpansionMidtoneHigh;
    float developmentExpansionCombinedHighlightWeight;
    float developmentExpansionCombinedRangeWeight;
    float developmentExpansionCombinedMidtoneWeight;
    uint chromaReconstructionMode;
    float chromaSampleCenterX;
    float chromaSampleCenterY;

    float bt709LumaR;
    float bt709LumaG;
    float bt709LumaB;
    float bt2020LumaR;
    float bt2020LumaG;
    float bt2020LumaB;
    float bt709ToBT2020_00;
    float bt709ToBT2020_01;
    float bt709ToBT2020_02;
    float bt709ToBT2020_10;
    float bt709ToBT2020_11;
    float bt709ToBT2020_12;
    float bt709ToBT2020_20;
    float bt709ToBT2020_21;
    float bt709ToBT2020_22;
    float bt709InverseBreakPoint;
    float bt709InverseLinearScale;
    float bt709InverseOffset;
    float bt709InverseScale;
    float bt709InverseExponent;
    float srgbInverseBreakPoint;
    float srgbInverseLinearScale;
    float srgbInverseOffset;
    float srgbInverseScale;
    float srgbInverseExponent;
    float bt601ToRGB_00;
    float bt601ToRGB_01;
    float bt601ToRGB_02;
    float bt601ToRGB_10;
    float bt601ToRGB_11;
    float bt601ToRGB_12;
    float bt601ToRGB_20;
    float bt601ToRGB_21;
    float bt601ToRGB_22;
    float bt709ToRGB_00;
    float bt709ToRGB_01;
    float bt709ToRGB_02;
    float bt709ToRGB_10;
    float bt709ToRGB_11;
    float bt709ToRGB_12;
    float bt709ToRGB_20;
    float bt709ToRGB_21;
    float bt709ToRGB_22;
    float bt2020ToRGB_00;
    float bt2020ToRGB_01;
    float bt2020ToRGB_02;
    float bt2020ToRGB_10;
    float bt2020ToRGB_11;
    float bt2020ToRGB_12;
    float bt2020ToRGB_20;
    float bt2020ToRGB_21;
    float bt2020ToRGB_22;
    float pqM1;
    float pqM2;
    float pqC1;
    float pqC2;
    float pqC3;
    float pqAbsolutePeakNits;
    float p010StorageDenominator;
    uint p010RightShift;
    float p010CodeMaximum;

    float toneInputMinimum;
    float toneInputMaximum;
    float toneSmoothstepFloor;
    float toneSmoothstepLinear;
    float toneSmoothstepQuadratic;
    float toneShoulderBase;
    float toneShoulderContrast;
    float toneLegacyShadowLower;
    float toneLegacyShadowUpper;
    float toneSceneFloorLower;
    float toneSceneFloorUpper;
    float toneSceneFloorFallback;
    float toneSceneTopMinimumDelta;
    float toneSceneTopFallback;
    float toneSceneTopUpper;
    float toneSceneLowMidCoefficient;
    float toneSceneProtectionCoefficient;
    float toneDefaultPresenceLower;
    float toneDefaultPresenceUpper;
    float toneDefaultFadeLower;
    float toneDefaultFadeUpper;
    float toneDefaultAttenuationCoefficient;
    float toneChromaStart;
    float toneChromaPeakMinimum;
    float toneChromaCoefficient;
    float toneGamutLuminanceFloor;
    float toneGamutDenominatorFloor;
    float toneChromaScaleMinimum;
    float toneChromaScaleMaximum;
    float toneOutputMinimum;
};

struct HDRDebugStats {
    atomic_uint inputLuminanceSum;
    atomic_uint inputLuminanceMax;
    atomic_uint outputLuminanceSum;
    atomic_uint outputLuminanceMax;
    atomic_uint highlightPixelCount;
    atomic_uint clippedPixelCount;
    atomic_uint pixelCount;
    atomic_uint toneExpandedLuminanceSum;
    atomic_uint toneExpandedLuminanceMax;
    atomic_uint coreLuminanceSum;
    atomic_uint coreLuminanceMax;
    atomic_uint lowMidContributionSum;
    atomic_uint shoulderContributionSum;
    atomic_uint shadowProtectionSum;
};

struct TemporalLumaStats {
    atomic_uint linearLuminanceSum;
    atomic_uint sampleCount;
    atomic_uint histogram[64];
};

inline float smoothStepSafe(float edge0, float edge1, float value) {
    float denominator = max(edge1 - edge0, 1e-6f);
    float t = clamp((value - edge0) / denominator, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

inline float smoothStepSemantic(float edge0, float edge1, float value, constant SDRToHDRParameters& p) {
    float denominator = max(edge1 - edge0, p.toneSmoothstepFloor);
    float t = clamp((value - edge0) / denominator, 0.0f, 1.0f);
    return t * t * (p.toneSmoothstepLinear - p.toneSmoothstepQuadratic * t);
}

inline float smoothStepRemapSemantic(float value, constant SDRToHDRParameters& p) {
    float t = clamp(value, 0.0f, 1.0f);
    return t * t * (p.toneSmoothstepLinear - p.toneSmoothstepQuadratic * t);
}

inline float inverseBT709(float value, constant SDRToHDRParameters& p) {
    value = max(value, 0.0f);
    return value < p.bt709InverseBreakPoint
        ? value / p.bt709InverseLinearScale
        : pow((value + p.bt709InverseOffset) / p.bt709InverseScale, p.bt709InverseExponent);
}

inline float inverseSRGB(float value, constant SDRToHDRParameters& p) {
    value = max(value, 0.0f);
    return value <= p.srgbInverseBreakPoint
        ? value / p.srgbInverseLinearScale
        : pow((value + p.srgbInverseOffset) / p.srgbInverseScale, p.srgbInverseExponent);
}

inline float inverseBT1886(float value, constant SDRToHDRParameters& p) {
    // HDRProcessor validates the complete parameter domain before dispatch.
    // Keep the valid-domain equation identical to HDRColorMath: no GPU-only
    // span floor may silently change a valid BT.1886 parameterization.
    float blackRoot = pow(p.bt1886BlackLuminance, 1.0f / p.gamma);
    float whiteRoot = pow(p.bt1886WhiteLuminance, 1.0f / p.gamma);
    float span = whiteRoot - blackRoot;
    float a = pow(span, p.gamma);
    float b = blackRoot / span;
    return a * pow(max(clamp(value, 0.0f, 1.0f) + b, 0.0f), p.gamma);
}

inline float inverseTransfer(float value, constant SDRToHDRParameters& p) {
    switch (p.transferFunction) {
        case 0: return inverseBT709(value, p);
        case 1: return inverseSRGB(value, p);
        case 2: return pow(max(value, 0.0f), p.gamma);
        case 4: return inverseBT1886(value, p);
        default: return max(value, 0.0f);
    }
}

inline float3 ycbcrToRGB(float y, float2 chroma, constant SDRToHDRParameters& p) {
    float cb = (chroma.x - p.chromaOffset) * p.chromaScale;
    float cr = (chroma.y - p.chromaOffset) * p.chromaScale;
    if (p.matrixKind == 1) {
        return float3(
            p.bt601ToRGB_00 * y + p.bt601ToRGB_01 * cb + p.bt601ToRGB_02 * cr,
            p.bt601ToRGB_10 * y + p.bt601ToRGB_11 * cb + p.bt601ToRGB_12 * cr,
            p.bt601ToRGB_20 * y + p.bt601ToRGB_21 * cb + p.bt601ToRGB_22 * cr
        );
    }
    if (p.matrixKind == 2) {
        return float3(
            p.bt2020ToRGB_00 * y + p.bt2020ToRGB_01 * cb + p.bt2020ToRGB_02 * cr,
            p.bt2020ToRGB_10 * y + p.bt2020ToRGB_11 * cb + p.bt2020ToRGB_12 * cr,
            p.bt2020ToRGB_20 * y + p.bt2020ToRGB_21 * cb + p.bt2020ToRGB_22 * cr
        );
    }
    return float3(
        p.bt709ToRGB_00 * y + p.bt709ToRGB_01 * cb + p.bt709ToRGB_02 * cr,
        p.bt709ToRGB_10 * y + p.bt709ToRGB_11 * cb + p.bt709ToRGB_12 * cr,
        p.bt709ToRGB_20 * y + p.bt709ToRGB_21 * cb + p.bt709ToRGB_22 * cr
    );
}

struct HDRToneExpansionBreakdown {
    float expandedLuminance;
    float lowMidContribution;
    float shoulderContribution;
    float shadowProtectionFactor;
    float effectiveStrength;
};

inline HDRToneExpansionBreakdown makeToneExpansionBreakdown(
    float expandedLuminance,
    float lowMidContribution,
    float shoulderContribution,
    float shadowProtectionFactor,
    float effectiveStrength
) {
    HDRToneExpansionBreakdown value;
    value.expandedLuminance = expandedLuminance;
    value.lowMidContribution = lowMidContribution;
    value.shoulderContribution = shoulderContribution;
    value.shadowProtectionFactor = shadowProtectionFactor;
    value.effectiveStrength = effectiveStrength;
    return value;
}

inline float toneExpand(float luminance, constant SDRToHDRParameters& p) {
    float y = clamp(luminance, p.toneInputMinimum, p.toneInputMaximum);
    float shoulderStart = p.toneShoulderBase - p.toneShoulderContrast * clamp(p.contrastStrength, 0.0f, 1.0f);
    float shoulderT = smoothStepSemantic(shoulderStart, p.toneInputMaximum, y, p);
    float shoulder = smoothStepRemapSemantic(shoulderT, p);
    float strength = clamp(p.highlightStrength * p.temporalAdaptation, 0.0f, 1.0f);

    if (p.toneCurveRevision == 0) {
        float legacyShadowGate = smoothStepSemantic(p.toneLegacyShadowLower, p.toneLegacyShadowUpper, y, p);
        float legacyProtection = 1.0f - clamp(p.shadowProtection, 0.0f, 1.0f) *
            (1.0f - legacyShadowGate);
        float legacyExpansion = (p.peakRatio - 1.0f) * strength * shoulder * y * legacyProtection;
        return clamp(y + max(legacyExpansion, 0.0f), y, p.peakRatio);
    }

    if (p.toneCurveRevision == 2) {
        // V4: shadow coordinates are derived from the source scene's causal
        // percentile estimator. If the first frame has no history yet, use a
        // conservative neutral band; the estimator updates the next frame.
        float shadowFloor = p.sceneStatisticsValid != 0 ? clamp(p.sceneShadowFloor, p.toneSceneFloorLower, p.toneSceneFloorUpper) : p.toneSceneFloorFallback;
        float shadowTop = p.sceneStatisticsValid != 0
            ? max(p.sceneShadowTop, shadowFloor + p.toneSceneTopMinimumDelta)
            : p.toneSceneTopFallback;
        shadowTop = min(shadowTop, p.toneSceneTopUpper);
        float shadowWeight = 1.0f - smoothStepSemantic(shadowFloor, shadowTop, y, p);
        float lowMidTransition = smoothStepSemantic(shadowFloor, shadowTop, y, p);
        float lowMidExpansion = (p.peakRatio - 1.0f) * strength * p.toneSceneLowMidCoefficient * lowMidTransition * y;
        float shoulderExpansion = (p.peakRatio - 1.0f) * strength * shoulder * y;
        float protection = 1.0f - p.toneSceneProtectionCoefficient * clamp(p.shadowProtection, 0.0f, 1.0f) * shadowWeight;
        float expanded = y + (lowMidExpansion + shoulderExpansion) * protection;
        return clamp(expanded, y, p.peakRatio);
    }

    if (p.toneCurveRevision == 3) {
        // V6 development candidate: retain the V4 shoulder and shadow
        // protection, but bound low-mid support so it fades to zero before
        // the shoulder. If a scene anchor crosses the shoulder, clip only
        // the low-mid support endpoint; the shadow protection transition
        // remains on the original scene-relative anchor.
        float shadowFloor = p.sceneStatisticsValid != 0 ? clamp(p.sceneShadowFloor, p.toneSceneFloorLower, p.toneSceneFloorUpper) : 0.01f;
        float shadowTop = p.sceneStatisticsValid != 0
            ? max(p.sceneShadowTop, shadowFloor + 0.025f)
            : 0.1125f;
        shadowTop = min(shadowTop, 0.60f);
        float shadowTransition = smoothStepSafe(shadowFloor, shadowTop, y);
        float supportTop = min(shadowTop, shoulderStart - 0.0001f);
        float lowMidRise = smoothStepSafe(shadowFloor, supportTop, y);
        float fadePosition = clamp(p.developmentLowMidFadePosition, 0.0f, 1.0f);
        float lowMidFadeStart = mix(supportTop, shoulderStart, fadePosition);
        float lowMidFall = 1.0f - smoothStepSafe(lowMidFadeStart, shoulderStart, y);
        float lowMidBand = lowMidRise * lowMidFall;
        float lowMidExpansion = (p.peakRatio - 1.0f) * strength *
            clamp(p.developmentLowMidStrength, 0.0f, 1.0f) * lowMidBand * y;
        float shoulderExpansion = (p.peakRatio - 1.0f) * strength * shoulder * y;
        float protection = 1.0f - 0.90f * clamp(p.shadowProtection, 0.0f, 1.0f) *
            (1.0f - shadowTransition);
        float expanded = y + (lowMidExpansion + shoulderExpansion) * protection;
        return clamp(expanded, y, p.peakRatio);
    }

    if (p.toneCurveRevision == 4) {
        // V6.2 keeps the exact V4 shoulder/protection arithmetic and applies
        // a bounded budget only to the broad low-mid term.  All controller
        // inputs are causal SDR statistics; no HDR-reference label exists in
        // this path.
        float shadowFloor = p.sceneStatisticsValid != 0 ? clamp(p.sceneShadowFloor, 0.001f, 0.20f) : 0.01f;
        float shadowTop = p.sceneStatisticsValid != 0
            ? max(p.sceneShadowTop, shadowFloor + 0.025f)
            : 0.1125f;
        shadowTop = min(shadowTop, 0.60f);
        float shadowTransition = smoothStepSafe(shadowFloor, shadowTop, y);
        float shadowWeight = 1.0f - shadowTransition;
        float highlightOccupancy = clamp(
            (p.sceneP99 - p.sceneP90) / max(1.0f - p.sceneP90, 0.05f), 0.0f, 1.0f
        );
        float dynamicRangeStops = log2(
            (max(p.sceneP99, 0.0f) + 0.005f) /
            (max(p.sceneP50, 0.0f) + 0.005f)
        );
        float midtoneSpan = max(p.sceneP99 - p.sceneP01, 0.0001f);
        float midtoneOccupancy = clamp(
            (min(p.sceneP90, 0.75f) - max(p.sceneP50, 0.10f)) / midtoneSpan,
            0.0f, 1.0f
        );
        float highlightDemand = smoothStepSafe(
            p.developmentExpansionHighlightLow,
            p.developmentExpansionHighlightHigh,
            highlightOccupancy
        );
        float dynamicDemand = smoothStepSafe(
            p.developmentExpansionRangeLow,
            p.developmentExpansionRangeHigh,
            dynamicRangeStops
        );
        float midtoneDemand = 1.0f - smoothStepSafe(
            p.developmentExpansionMidtoneLow,
            p.developmentExpansionMidtoneHigh,
            midtoneOccupancy
        );
        float budgetSignal;
        if (p.developmentExpansionController == 0) {
            budgetSignal = highlightDemand;
        } else if (p.developmentExpansionController == 1) {
            budgetSignal = dynamicDemand;
        } else {
            float weightSum = max(
                p.developmentExpansionCombinedHighlightWeight +
                p.developmentExpansionCombinedRangeWeight +
                p.developmentExpansionCombinedMidtoneWeight,
                0.000001f
            );
            budgetSignal = (
                p.developmentExpansionCombinedHighlightWeight * highlightDemand +
                p.developmentExpansionCombinedRangeWeight * dynamicDemand +
                p.developmentExpansionCombinedMidtoneWeight * midtoneDemand
            ) / weightSum;
        }
        float minimumBudget = clamp(p.developmentExpansionMinimumBudget, 0.0f, 1.0f);
        float expansionBudget = clamp(minimumBudget + (1.0f - minimumBudget) * budgetSignal, 0.0f, 1.0f);
        float lowMidTransition = smoothStepSafe(shadowFloor, shadowTop, y);
        float lowMidExpansion = (p.peakRatio - 1.0f) * strength * 0.08f *
            lowMidTransition * y * expansionBudget;
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
    float shadowPresence = smoothStepSemantic(p.toneDefaultPresenceLower, p.toneDefaultPresenceUpper, y, p) *
        (1.0f - smoothStepSemantic(p.toneDefaultFadeLower, p.toneDefaultFadeUpper, y, p));
    float shadowAttenuation = p.toneDefaultAttenuationCoefficient * clamp(p.shadowProtection, 0.0f, 1.0f) * shadowPresence;
    float protectedBase = y * (1.0f - shadowAttenuation);
    float expansion = (p.peakRatio - 1.0f) * strength * shoulder * y;
    return clamp(protectedBase + max(expansion, 0.0f), 0.0f, p.peakRatio);
}

// Observation-only decomposition. The production toneExpand() above remains
// the sole function used to produce output pixels.
inline HDRToneExpansionBreakdown toneExpandBreakdown(float luminance, constant SDRToHDRParameters& p) {
    float y = clamp(luminance, p.toneInputMinimum, p.toneInputMaximum);
    float shoulderStart = p.toneShoulderBase - p.toneShoulderContrast * clamp(p.contrastStrength, 0.0f, 1.0f);
    float shoulderT = smoothStepSemantic(shoulderStart, p.toneInputMaximum, y, p);
    float shoulder = smoothStepRemapSemantic(shoulderT, p);
    float strength = clamp(p.highlightStrength * p.temporalAdaptation, 0.0f, 1.0f);

    if (p.toneCurveRevision == 0) {
        float legacyShadowGate = smoothStepSemantic(p.toneLegacyShadowLower, p.toneLegacyShadowUpper, y, p);
        float legacyProtection = 1.0f - clamp(p.shadowProtection, 0.0f, 1.0f) *
            (1.0f - legacyShadowGate);
        float legacyExpansion = (p.peakRatio - 1.0f) * strength * shoulder * y * legacyProtection;
        return makeToneExpansionBreakdown(
            toneExpand(luminance, p),
            0.0f,
            max(legacyExpansion, 0.0f),
            legacyProtection,
            strength
        );
    }

    if (p.toneCurveRevision == 2) {
        float shadowFloor = p.sceneStatisticsValid != 0 ? clamp(p.sceneShadowFloor, p.toneSceneFloorLower, p.toneSceneFloorUpper) : p.toneSceneFloorFallback;
        float shadowTop = p.sceneStatisticsValid != 0
            ? max(p.sceneShadowTop, shadowFloor + p.toneSceneTopMinimumDelta)
            : p.toneSceneTopFallback;
        shadowTop = min(shadowTop, p.toneSceneTopUpper);
        float shadowWeight = 1.0f - smoothStepSemantic(shadowFloor, shadowTop, y, p);
        float lowMidTransition = smoothStepSemantic(shadowFloor, shadowTop, y, p);
        float lowMidExpansion = (p.peakRatio - 1.0f) * strength * p.toneSceneLowMidCoefficient * lowMidTransition * y;
        float shoulderExpansion = (p.peakRatio - 1.0f) * strength * shoulder * y;
        float protection = 1.0f - p.toneSceneProtectionCoefficient * clamp(p.shadowProtection, 0.0f, 1.0f) * shadowWeight;
        return makeToneExpansionBreakdown(
            toneExpand(luminance, p),
            max(lowMidExpansion * protection, 0.0f),
            max(shoulderExpansion * protection, 0.0f),
            protection,
            strength
        );
    }

    if (p.toneCurveRevision == 3) {
        float shadowFloor = p.sceneStatisticsValid != 0 ? clamp(p.sceneShadowFloor, 0.001f, 0.20f) : 0.01f;
        float shadowTop = p.sceneStatisticsValid != 0
            ? max(p.sceneShadowTop, shadowFloor + 0.025f)
            : 0.1125f;
        shadowTop = min(shadowTop, 0.60f);
        float shadowTransition = smoothStepSafe(shadowFloor, shadowTop, y);
        float supportTop = min(shadowTop, shoulderStart - 0.0001f);
        float lowMidRise = smoothStepSafe(shadowFloor, supportTop, y);
        float fadePosition = clamp(p.developmentLowMidFadePosition, 0.0f, 1.0f);
        float lowMidFadeStart = mix(supportTop, shoulderStart, fadePosition);
        float lowMidFall = 1.0f - smoothStepSafe(lowMidFadeStart, shoulderStart, y);
        float lowMidBand = lowMidRise * lowMidFall;
        float lowMidExpansion = (p.peakRatio - 1.0f) * strength *
            clamp(p.developmentLowMidStrength, 0.0f, 1.0f) * lowMidBand * y;
        float shoulderExpansion = (p.peakRatio - 1.0f) * strength * shoulder * y;
        float protection = 1.0f - 0.90f * clamp(p.shadowProtection, 0.0f, 1.0f) *
            (1.0f - shadowTransition);
        return makeToneExpansionBreakdown(
            toneExpand(luminance, p),
            max(lowMidExpansion * protection, 0.0f),
            max(shoulderExpansion * protection, 0.0f),
            protection,
            strength
        );
    }

    if (p.toneCurveRevision == 4) {
        float shadowFloor = p.sceneStatisticsValid != 0 ? clamp(p.sceneShadowFloor, 0.001f, 0.20f) : 0.01f;
        float shadowTop = p.sceneStatisticsValid != 0
            ? max(p.sceneShadowTop, shadowFloor + 0.025f)
            : 0.1125f;
        shadowTop = min(shadowTop, 0.60f);
        float shadowTransition = smoothStepSafe(shadowFloor, shadowTop, y);
        float shadowWeight = 1.0f - shadowTransition;
        float highlightOccupancy = clamp(
            (p.sceneP99 - p.sceneP90) / max(1.0f - p.sceneP90, 0.05f), 0.0f, 1.0f
        );
        float dynamicRangeStops = log2(
            (max(p.sceneP99, 0.0f) + 0.005f) /
            (max(p.sceneP50, 0.0f) + 0.005f)
        );
        float midtoneSpan = max(p.sceneP99 - p.sceneP01, 0.0001f);
        float midtoneOccupancy = clamp(
            (min(p.sceneP90, 0.75f) - max(p.sceneP50, 0.10f)) / midtoneSpan,
            0.0f, 1.0f
        );
        float highlightDemand = smoothStepSafe(
            p.developmentExpansionHighlightLow,
            p.developmentExpansionHighlightHigh,
            highlightOccupancy
        );
        float dynamicDemand = smoothStepSafe(
            p.developmentExpansionRangeLow,
            p.developmentExpansionRangeHigh,
            dynamicRangeStops
        );
        float midtoneDemand = 1.0f - smoothStepSafe(
            p.developmentExpansionMidtoneLow,
            p.developmentExpansionMidtoneHigh,
            midtoneOccupancy
        );
        float budgetSignal;
        if (p.developmentExpansionController == 0) {
            budgetSignal = highlightDemand;
        } else if (p.developmentExpansionController == 1) {
            budgetSignal = dynamicDemand;
        } else {
            float weightSum = max(
                p.developmentExpansionCombinedHighlightWeight +
                p.developmentExpansionCombinedRangeWeight +
                p.developmentExpansionCombinedMidtoneWeight,
                0.000001f
            );
            budgetSignal = (
                p.developmentExpansionCombinedHighlightWeight * highlightDemand +
                p.developmentExpansionCombinedRangeWeight * dynamicDemand +
                p.developmentExpansionCombinedMidtoneWeight * midtoneDemand
            ) / weightSum;
        }
        float minimumBudget = clamp(p.developmentExpansionMinimumBudget, 0.0f, 1.0f);
        float expansionBudget = clamp(minimumBudget + (1.0f - minimumBudget) * budgetSignal, 0.0f, 1.0f);
        float lowMidTransition = smoothStepSafe(shadowFloor, shadowTop, y);
        float lowMidExpansion = (p.peakRatio - 1.0f) * strength * 0.08f *
            lowMidTransition * y * expansionBudget;
        float shoulderExpansion = (p.peakRatio - 1.0f) * strength * shoulder * y;
        float protection = 1.0f - 0.90f * clamp(p.shadowProtection, 0.0f, 1.0f) * shadowWeight;
        return makeToneExpansionBreakdown(
            toneExpand(luminance, p),
            max(lowMidExpansion * protection, 0.0f),
            max(shoulderExpansion * protection, 0.0f),
            protection,
            strength
        );
    }

    float shadowPresence = smoothStepSemantic(p.toneDefaultPresenceLower, p.toneDefaultPresenceUpper, y, p) *
        (1.0f - smoothStepSemantic(p.toneDefaultFadeLower, p.toneDefaultFadeUpper, y, p));
    float shadowAttenuation = p.toneDefaultAttenuationCoefficient * clamp(p.shadowProtection, 0.0f, 1.0f) * shadowPresence;
    float expansion = (p.peakRatio - 1.0f) * strength * shoulder * y;
    return makeToneExpansionBreakdown(
        toneExpand(luminance, p),
        0.0f,
        max(expansion, 0.0f),
        1.0f - shadowAttenuation,
        strength
    );
}

inline float3 gamutCompress(float3 rgb, float luminance, float peakRatio, constant SDRToHDRParameters& p) {
    float safeLuminance = max(luminance, p.toneGamutLuminanceFloor);
    float minimum = min(rgb.x, min(rgb.y, rgb.z));
    float maximum = max(rgb.x, max(rgb.y, rgb.z));
    float chromaScale = 1.0f;
    if (minimum < 0.0f && safeLuminance > 0.0f) {
        chromaScale = min(chromaScale, safeLuminance / max(safeLuminance - minimum, p.toneGamutDenominatorFloor));
    }
    if (maximum > peakRatio && maximum > safeLuminance) {
        chromaScale = min(chromaScale, max(peakRatio - safeLuminance, 0.0f) / max(maximum - safeLuminance, p.toneGamutDenominatorFloor));
    }
    float3 neutral = float3(safeLuminance);
    return neutral + (rgb - neutral) * clamp(chromaScale, p.toneChromaScaleMinimum, p.toneChromaScaleMaximum);
}

inline float pqEncode(float normalizedLuminance, constant SDRToHDRParameters& p) {
    float luminance = clamp(normalizedLuminance, 0.0f, 1.0f);
    float powered = pow(luminance, p.pqM1);
    return pow((p.pqC1 + p.pqC2 * powered) / (1.0f + p.pqC3 * powered), p.pqM2);
}

inline float pqDecode(float signal, constant SDRToHDRParameters& p) {
    float powered = pow(clamp(signal, 0.0f, 1.0f), 1.0f / p.pqM2);
    return pow(max(powered - p.pqC1, 0.0f) / max(p.pqC2 - p.pqC3 * powered, p.toneGamutDenominatorFloor), 1.0f / p.pqM1);
}

inline float3 linearizeSignal(float3 signal, constant SDRToHDRParameters& p) {
    signal = clamp(signal, 0.0f, 1.0f);
    return max(float3(
        inverseTransfer(signal.x, p),
        inverseTransfer(signal.y, p),
        inverseTransfer(signal.z, p)
    ), 0.0f);
}

constant uint kDiagnosticBinCount = 64;
constant float kDiagnosticLuminanceRange = 8.0f;
constant float kDiagnosticSumScale = 16.0f;
constant float kDiagnosticContributionSumScale = 64.0f;
constant float kDiagnosticRGBSumScale = 32.0f;
constant float kDiagnosticChromaSumScale = 256.0f;
constant float kNearBlackSumScale = 32.0f;

inline uint diagnosticBin(float value, float range) {
    return min(uint(clamp(value, 0.0f, range - 1e-6f) / range * float(kDiagnosticBinCount)), kDiagnosticBinCount - 1);
}

inline void addDiagnosticHistogram(
    device atomic_uint* histograms,
    uint group,
    float value,
    float range
) {
    atomic_fetch_add_explicit(
        &histograms[group * kDiagnosticBinCount + diagnosticBin(value, range)],
        1u,
        memory_order_relaxed
    );
}

inline float3 coreRelativeRGB(float3 encodedOutput, constant SDRToHDRParameters& p) {
    if (p.outputMode == 0) return encodedOutput;
    return float3(
        pqDecode(encodedOutput.x, p),
        pqDecode(encodedOutput.y, p),
        pqDecode(encodedOutput.z, p)
    ) * (p.pqAbsolutePeakNits / max(p.paperWhiteNits, p.toneGamutDenominatorFloor));
}

inline bool diagnosticROIContains(
    uint2 gid,
    uint width,
    uint height,
    constant SDRToHDRParameters& p
) {
    if (p.diagnosticROIEnabled == 0) return false;
    float2 uv = (float2(gid) + 0.5f) / float2(max(width, 1u), max(height, 1u));
    return uv.x >= p.diagnosticROIX && uv.y >= p.diagnosticROIY &&
        uv.x < p.diagnosticROIX + p.diagnosticROIWidth &&
        uv.y < p.diagnosticROIY + p.diagnosticROIHeight;
}

inline void accumulateNearBlack(
    uint band,
    float inputLuminance,
    float toneLuminance,
    float coreLuminance,
    device atomic_uint* details
) {
    uint start = 16u + band * 9u;
    float coreGain = clamp(coreLuminance / max(inputLuminance, 1e-6f), 0.0f, 4.0f);
    float toneGain = clamp(toneLuminance / max(inputLuminance, 1e-6f), 0.0f, 4.0f);
    atomic_fetch_add_explicit(&details[start + 0u], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&details[start + 1u], uint(coreGain * kNearBlackSumScale + 0.5f), memory_order_relaxed);
    atomic_fetch_add_explicit(&details[start + 2u], uint(toneGain * kNearBlackSumScale + 0.5f), memory_order_relaxed);
    atomic_fetch_add_explicit(&details[start + 3u], toneLuminance > inputLuminance + 1e-4f ? 1u : 0u, memory_order_relaxed);
    atomic_fetch_add_explicit(&details[start + 4u], coreLuminance < inputLuminance - 1e-4f ? 1u : 0u, memory_order_relaxed);
    uint inputQuantized = uint(clamp(inputLuminance, 0.0f, 8.0f) * 256.0f + 0.5f);
    uint coreQuantized = uint(clamp(coreLuminance, 0.0f, 8.0f) * 256.0f + 0.5f);
    atomic_fetch_min_explicit(&details[start + 5u], inputQuantized, memory_order_relaxed);
    atomic_fetch_max_explicit(&details[start + 6u], inputQuantized, memory_order_relaxed);
    atomic_fetch_min_explicit(&details[start + 7u], coreQuantized, memory_order_relaxed);
    atomic_fetch_max_explicit(&details[start + 8u], coreQuantized, memory_order_relaxed);
}

inline void accumulateDebug(
    float3 inputSignal,
    float3 encodedOutput,
    constant SDRToHDRParameters& p,
    device HDRDebugStats* stats,
    device atomic_uint* histograms,
    device atomic_uint* details,
    uint2 gid,
    uint width,
    uint height
) {
    float3 inputLinear = linearizeSignal(inputSignal, p);
    float inputLuminance = clamp(
        dot(inputLinear, float3(p.bt709LumaR, p.bt709LumaG, p.bt709LumaB)),
        0.0f,
        1.0f
    );
    HDRToneExpansionBreakdown tone = toneExpandBreakdown(inputLuminance, p);
    float3 coreRGB = max(coreRelativeRGB(encodedOutput, p), 0.0f);
    float coreLuminance = max(
        dot(coreRGB, float3(p.bt2020LumaR, p.bt2020LumaG, p.bt2020LumaB)),
        0.0f
    );
    float outputPeakRatio = p.outputMode == 0 ? min(p.peakRatio, p.masteringHeadroom) : p.peakRatio;
    float outputLuminance = clamp(coreLuminance / max(outputPeakRatio, 1e-6f), 0.0f, 1.0f);
    // The 256 scale keeps the uint32 sums bounded through 4K frames while
    // retaining useful DEBUG-build trend information.
    uint inputQuantized = uint(inputLuminance * 256.0f + 0.5f);
    uint outputQuantized = uint(outputLuminance * 256.0f + 0.5f);
    atomic_fetch_add_explicit(&stats->inputLuminanceSum, inputQuantized, memory_order_relaxed);
    atomic_fetch_max_explicit(&stats->inputLuminanceMax, inputQuantized, memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->outputLuminanceSum, outputQuantized, memory_order_relaxed);
    atomic_fetch_max_explicit(&stats->outputLuminanceMax, outputQuantized, memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->toneExpandedLuminanceSum, uint(tone.expandedLuminance * kDiagnosticSumScale + 0.5f), memory_order_relaxed);
    atomic_fetch_max_explicit(&stats->toneExpandedLuminanceMax, uint(tone.expandedLuminance * 256.0f + 0.5f), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->coreLuminanceSum, uint(coreLuminance * kDiagnosticSumScale + 0.5f), memory_order_relaxed);
    atomic_fetch_max_explicit(&stats->coreLuminanceMax, uint(coreLuminance * 256.0f + 0.5f), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->lowMidContributionSum, uint(tone.lowMidContribution * kDiagnosticContributionSumScale + 0.5f), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->shoulderContributionSum, uint(tone.shoulderContribution * kDiagnosticContributionSumScale + 0.5f), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->shadowProtectionSum, uint(clamp(tone.shadowProtectionFactor, 0.0f, 1.0f) * kDiagnosticContributionSumScale + 0.5f), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->highlightPixelCount, inputLuminance >= 0.75f ? 1u : 0u, memory_order_relaxed);
    float peakSignal = p.outputMode == 0 ? outputPeakRatio : pqEncode(p.peakNits / p.pqAbsolutePeakNits, p);
    atomic_fetch_add_explicit(&stats->clippedPixelCount, max(encodedOutput.x, max(encodedOutput.y, encodedOutput.z)) >= peakSignal - 0.0005f ? 1u : 0u, memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->pixelCount, 1u, memory_order_relaxed);

    addDiagnosticHistogram(histograms, 0u, inputLuminance, kDiagnosticLuminanceRange);
    addDiagnosticHistogram(histograms, 1u, tone.expandedLuminance, kDiagnosticLuminanceRange);
    addDiagnosticHistogram(histograms, 2u, coreLuminance, kDiagnosticLuminanceRange);
    addDiagnosticHistogram(histograms, 3u, tone.lowMidContribution, 1.0f);
    addDiagnosticHistogram(histograms, 4u, tone.shoulderContribution, 1.0f);
    addDiagnosticHistogram(histograms, 5u, tone.shadowProtectionFactor, 1.0f);

    if (inputLuminance < 0.01f) accumulateNearBlack(0u, inputLuminance, tone.expandedLuminance, coreLuminance, details);
    if (inputLuminance < 0.02f) accumulateNearBlack(1u, inputLuminance, tone.expandedLuminance, coreLuminance, details);
    if (inputLuminance < 0.05f) accumulateNearBlack(2u, inputLuminance, tone.expandedLuminance, coreLuminance, details);

    if (diagnosticROIContains(gid, width, height, p)) {
        addDiagnosticHistogram(histograms, 6u, inputLuminance, kDiagnosticLuminanceRange);
        addDiagnosticHistogram(histograms, 7u, tone.expandedLuminance, kDiagnosticLuminanceRange);
        addDiagnosticHistogram(histograms, 8u, coreLuminance, kDiagnosticLuminanceRange);
        addDiagnosticHistogram(histograms, 9u, tone.lowMidContribution, 1.0f);
        addDiagnosticHistogram(histograms, 10u, tone.shoulderContribution, 1.0f);
        addDiagnosticHistogram(histograms, 11u, tone.shadowProtectionFactor, 1.0f);
        float inputMinimum = min(inputLinear.x, min(inputLinear.y, inputLinear.z));
        float inputMaximum = max(inputLinear.x, max(inputLinear.y, inputLinear.z));
        float coreMinimum = min(coreRGB.x, min(coreRGB.y, coreRGB.z));
        float coreMaximum = max(coreRGB.x, max(coreRGB.y, coreRGB.z));
        float inputSaturation = clamp((inputMaximum - inputMinimum) / max(inputLuminance, 1e-6f), 0.0f, 1.0f);
        float coreSaturation = clamp((coreMaximum - coreMinimum) / max(coreLuminance, 1e-6f), 0.0f, 1.0f);
        float saturationDelta = clamp(coreSaturation - inputSaturation, -0.5f, 0.5f);
        atomic_fetch_add_explicit(&details[0], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&details[1], uint(clamp(coreRGB.x, 0.0f, 8.0f) * kDiagnosticRGBSumScale + 0.5f), memory_order_relaxed);
        atomic_fetch_add_explicit(&details[2], uint(clamp(coreRGB.y, 0.0f, 8.0f) * kDiagnosticRGBSumScale + 0.5f), memory_order_relaxed);
        atomic_fetch_add_explicit(&details[3], uint(clamp(coreRGB.z, 0.0f, 8.0f) * kDiagnosticRGBSumScale + 0.5f), memory_order_relaxed);
        atomic_fetch_add_explicit(&details[4], uint(clamp(coreSaturation, 0.0f, 1.0f) * kDiagnosticChromaSumScale + 0.5f), memory_order_relaxed);
        atomic_fetch_add_explicit(&details[5], uint((saturationDelta + 0.5f) * kDiagnosticChromaSumScale + 0.5f), memory_order_relaxed);
        atomic_fetch_max_explicit(&details[6], uint(inputLuminance * 256.0f + 0.5f), memory_order_relaxed);
        atomic_fetch_max_explicit(&details[7], uint(tone.expandedLuminance * 256.0f + 0.5f), memory_order_relaxed);
        atomic_fetch_max_explicit(&details[8], uint(coreLuminance * 256.0f + 0.5f), memory_order_relaxed);
    }
}

inline float3 transformSignalRGB(float3 signal, constant SDRToHDRParameters& p) {
    float3 linear = linearizeSignal(signal, p);
    float luminance = max(
        dot(linear, float3(p.bt709LumaR, p.bt709LumaG, p.bt709LumaB)),
        0.0f
    );
    float expandedLuminance = toneExpand(luminance, p);
    // Preserve near-black light; only exact black requires a divide guard.
    float gain = luminance > 0.0f ? expandedLuminance / luminance : 0.0f;
    float3 expanded = linear * gain;
    // Use the fixed output-domain peak as the upper edge. Using the sample
    // itself as edge1 made every value >= 1.001 land at t=1, collapsing the
    // entire highlight chroma transition into a 0.1% luminance interval.
    float chromaReduction = clamp(
        p.saturationCompensation * smoothStepSemantic(
            p.toneChromaStart,
            max(p.toneChromaPeakMinimum, p.peakRatio),
            expandedLuminance,
            p
        ) * p.toneChromaCoefficient,
        p.toneChromaScaleMinimum,
        p.toneChromaScaleMaximum
    );
    expanded = mix(expanded, float3(expandedLuminance), chromaReduction);

    float3 bt2020 = float3(
        p.bt709ToBT2020_00 * expanded.x + p.bt709ToBT2020_01 * expanded.y + p.bt709ToBT2020_02 * expanded.z,
        p.bt709ToBT2020_10 * expanded.x + p.bt709ToBT2020_11 * expanded.y + p.bt709ToBT2020_12 * expanded.z,
        p.bt709ToBT2020_20 * expanded.x + p.bt709ToBT2020_21 * expanded.y + p.bt709ToBT2020_22 * expanded.z
    );
    float outputPeakRatio = p.outputMode == 0 ? min(p.peakRatio, p.masteringHeadroom) : p.peakRatio;
    bt2020 = gamutCompress(
        bt2020,
        dot(bt2020, float3(p.bt2020LumaR, p.bt2020LumaG, p.bt2020LumaB)),
        outputPeakRatio,
        p
    );
    bt2020 = clamp(bt2020, p.toneOutputMinimum, outputPeakRatio);

    if (p.outputMode == 0) {
        return bt2020;
    }
    return float3(
        pqEncode(bt2020.x * p.paperWhiteNits / p.pqAbsolutePeakNits, p),
        pqEncode(bt2020.y * p.paperWhiteNits / p.pqAbsolutePeakNits, p),
        pqEncode(bt2020.z * p.paperWhiteNits / p.pqAbsolutePeakNits, p)
    );
}

// Apple P010 stores ten valid bits in the most-significant bits of each
// little-endian 16-bit plane sample. A .r16Unorm/.rg16Unorm read is normalized
// by Metal against 65535, so recover the integer code value before applying
// the 10-bit range coefficients supplied by ColorManagement.swift.
inline float p010CodeFromUnorm(float stored, constant SDRToHDRParameters& p) {
    return clamp(
        round(stored * p.p010StorageDenominator / exp2(float(p.p010RightShift))),
        0.0f,
        p.p010CodeMaximum
    );
}

inline float p010LumaSignal(float stored, constant SDRToHDRParameters& p) {
    float code = p010CodeFromUnorm(stored, p) / p.p010CodeMaximum;
    return (code - p.yOffset) * p.yScale;
}

inline float2 p010ChromaSignal(float2 stored, constant SDRToHDRParameters& p) {
    return float2(
        p010CodeFromUnorm(stored.x, p) / p.p010CodeMaximum,
        p010CodeFromUnorm(stored.y, p) / p.p010CodeMaximum
    );
}

// The coordinate of a luma sample is expressed in luma pixel-edge units,
// with the first luma pixel centered at (0.5, 0.5). The geometry resolver
// supplies the first chroma sample center in the same units. A texture
// coordinate of zero therefore addresses that first chroma sample, and each
// following chroma sample is two luma pixels farther away.
inline float2 reconstructedChroma(
    texture2d<float, access::read> uvTexture,
    uint2 lumaPosition,
    constant SDRToHDRParameters& p
) {
    uint2 lastPosition = uint2(
        uvTexture.get_width() - 1,
        uvTexture.get_height() - 1
    );

    if (p.chromaReconstructionMode == 0u) {
        uint2 nearestPosition = uint2(
            min(lumaPosition.x / 2, lastPosition.x),
            min(lumaPosition.y / 2, lastPosition.y)
        );
        return uvTexture.read(nearestPosition).rg;
    }

    float2 lumaCenter = float2(lumaPosition) + 0.5f;
    float2 chromaCoordinate = (
        lumaCenter - float2(p.chromaSampleCenterX, p.chromaSampleCenterY)
    ) / 2.0f;
    chromaCoordinate = clamp(chromaCoordinate, 0.0f, float2(lastPosition));

    uint2 lowerPosition = uint2(floor(chromaCoordinate));
    uint2 upperPosition = min(lowerPosition + uint2(1), lastPosition);
    float2 fraction = chromaCoordinate - float2(lowerPosition);

    float2 lowerRow = mix(
        uvTexture.read(lowerPosition).rg,
        uvTexture.read(uint2(upperPosition.x, lowerPosition.y)).rg,
        fraction.x
    );
    float2 upperRow = mix(
        uvTexture.read(uint2(lowerPosition.x, upperPosition.y)).rg,
        uvTexture.read(upperPosition).rg,
        fraction.x
    );
    return mix(lowerRow, upperRow, fraction.y);
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
    float y = (yTexture.read(gid).r - p.yOffset) * p.yScale;
    float2 uv = reconstructedChroma(uvTexture, gid, p);
    float3 signalRGB = ycbcrToRGB(y, uv, p);
    outputTexture.write(half4(float4(transformSignalRGB(signalRGB, p), 1.0f)), gid);
}

kernel void sdrP010ToHDR(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    float y = p010LumaSignal(yTexture.read(gid).r, p);
    float2 uv = p010ChromaSignal(reconstructedChroma(uvTexture, gid, p), p);
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
    device atomic_uint* histograms [[buffer(2)]],
    device atomic_uint* details [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    float y = (yTexture.read(gid).r - p.yOffset) * p.yScale;
    float3 signalRGB = ycbcrToRGB(y, reconstructedChroma(uvTexture, gid, p), p);
    float3 output = transformSignalRGB(signalRGB, p);
    outputTexture.write(half4(float4(output, 1.0f)), gid);
    accumulateDebug(signalRGB, output, p, stats, histograms, details, gid,
                    outputTexture.get_width(), outputTexture.get_height());
}

kernel void sdrP010ToHDRDebug(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    device HDRDebugStats* stats [[buffer(1)]],
    device atomic_uint* histograms [[buffer(2)]],
    device atomic_uint* details [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    float y = p010LumaSignal(yTexture.read(gid).r, p);
    float3 signalRGB = ycbcrToRGB(y, p010ChromaSignal(reconstructedChroma(uvTexture, gid, p), p), p);
    float3 output = transformSignalRGB(signalRGB, p);
    outputTexture.write(half4(float4(output, 1.0f)), gid);
    accumulateDebug(signalRGB, output, p, stats, histograms, details, gid,
                    outputTexture.get_width(), outputTexture.get_height());
}

kernel void sdrBGRA8ToHDRDebug(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    device HDRDebugStats* stats [[buffer(1)]],
    device atomic_uint* histograms [[buffer(2)]],
    device atomic_uint* details [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    float3 signalRGB = inputTexture.read(gid).rgb;
    float3 output = transformSignalRGB(signalRGB, p);
    outputTexture.write(half4(float4(output, 1.0f)), gid);
    accumulateDebug(signalRGB, output, p, stats, histograms, details, gid,
                    outputTexture.get_width(), outputTexture.get_height());
}

inline uint sceneHistogramBin(float luminance, constant SDRToHDRParameters& p) {
    float clamped = clamp(luminance, p.sceneInputMinimum, p.sceneHistogramUpperExclusive);
    uint strategy = p.histogramStrategy;
    uint binCount = strategy == 0u ? p.sceneLinear16HistogramBinCount : p.sceneHistogramBinCount;
    if (strategy == 0u) {
        return min(uint(clamped * float(binCount)), binCount - 1u);
    }
    if (strategy == 2u) {
        float logValue = clamp(luminance, exp2(p.sceneHistogramLogMinimumExponent), p.sceneInputMaximum);
        float normalized = (log2(logValue) - p.sceneHistogramLogMinimumExponent) /
            (p.sceneHistogramLogMaximumExponent - p.sceneHistogramLogMinimumExponent);
        return min(max(uint(normalized * float(binCount)), 0u), binCount - 1u);
    }
    if (strategy == 3u) {
        if (clamped < p.sceneShadowDenseBreakpoint) {
            return min(
                uint(clamped / p.sceneShadowDenseBreakpoint * float(p.sceneShadowDenseLowerBinCount)),
                p.sceneShadowDenseLowerBinCount - 1u
            );
        }
        return min(
            p.sceneShadowDenseLowerBinCount + uint(
                (clamped - p.sceneShadowDenseBreakpoint) / p.sceneShadowDenseUpperSpan *
                float(binCount - p.sceneShadowDenseLowerBinCount)
            ),
            binCount - 1u
        );
    }
    return min(uint(clamped * float(binCount)), binCount - 1u);
}

// A 16x9 sparse proxy (144 reads) estimates source luminance asynchronously.
// It is independent of output resolution and does not read the HDR texture.
kernel void estimateNV12TemporalLuminance(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    device TemporalLumaStats* stats [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.sceneProxyWidth || gid.y >= p.sceneProxyHeight) return;
    uint2 position = uint2(
        min((gid.x * yTexture.get_width() + yTexture.get_width() / 2) / p.sceneProxyWidth, yTexture.get_width() - 1),
        min((gid.y * yTexture.get_height() + yTexture.get_height() / 2) / p.sceneProxyHeight, yTexture.get_height() - 1)
    );
    float y = (yTexture.read(position).r - p.yOffset) * p.yScale;
    float3 signalRGB = ycbcrToRGB(y, reconstructedChroma(uvTexture, position, p), p);
    float3 linearRGB = linearizeSignal(signalRGB, p);
    float luminance = clamp(dot(linearRGB, float3(p.bt709LumaR, p.bt709LumaG, p.bt709LumaB)), p.sceneInputMinimum, p.sceneInputMaximum);
    atomic_fetch_add_explicit(&stats->linearLuminanceSum, uint(luminance * p.sceneQuantizationMaximum + p.sceneQuantizationRounding), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->sampleCount, 1u, memory_order_relaxed);
    if (p.toneCurveRevision >= 2) {
        uint bin = sceneHistogramBin(luminance, p);
        atomic_fetch_add_explicit(&stats->histogram[bin], 1u, memory_order_relaxed);
    }
}

kernel void estimateP010TemporalLuminance(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    device TemporalLumaStats* stats [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.sceneProxyWidth || gid.y >= p.sceneProxyHeight) return;
    uint2 position = uint2(
        min((gid.x * yTexture.get_width() + yTexture.get_width() / 2) / p.sceneProxyWidth, yTexture.get_width() - 1),
        min((gid.y * yTexture.get_height() + yTexture.get_height() / 2) / p.sceneProxyHeight, yTexture.get_height() - 1)
    );
    float y = p010LumaSignal(yTexture.read(position).r, p);
    float3 signalRGB = ycbcrToRGB(y, p010ChromaSignal(reconstructedChroma(uvTexture, position, p), p), p);
    float3 linearRGB = linearizeSignal(signalRGB, p);
    float luminance = clamp(dot(linearRGB, float3(p.bt709LumaR, p.bt709LumaG, p.bt709LumaB)), p.sceneInputMinimum, p.sceneInputMaximum);
    atomic_fetch_add_explicit(&stats->linearLuminanceSum, uint(luminance * p.sceneQuantizationMaximum + p.sceneQuantizationRounding), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->sampleCount, 1u, memory_order_relaxed);
    if (p.toneCurveRevision >= 2) {
        uint bin = sceneHistogramBin(luminance, p);
        atomic_fetch_add_explicit(&stats->histogram[bin], 1u, memory_order_relaxed);
    }
}

kernel void estimateBGRATemporalLuminance(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    constant SDRToHDRParameters& p [[buffer(0)]],
    device TemporalLumaStats* stats [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.sceneProxyWidth || gid.y >= p.sceneProxyHeight) return;
    uint2 position = uint2(
        min((gid.x * inputTexture.get_width() + inputTexture.get_width() / 2) / p.sceneProxyWidth, inputTexture.get_width() - 1),
        min((gid.y * inputTexture.get_height() + inputTexture.get_height() / 2) / p.sceneProxyHeight, inputTexture.get_height() - 1)
    );
    float3 linear = linearizeSignal(inputTexture.read(position).rgb, p);
    float luminance = clamp(dot(linear, float3(p.bt709LumaR, p.bt709LumaG, p.bt709LumaB)), p.sceneInputMinimum, p.sceneInputMaximum);
    atomic_fetch_add_explicit(&stats->linearLuminanceSum, uint(luminance * p.sceneQuantizationMaximum + p.sceneQuantizationRounding), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->sampleCount, 1u, memory_order_relaxed);
    if (p.toneCurveRevision >= 2) {
        uint bin = sceneHistogramBin(luminance, p);
        atomic_fetch_add_explicit(&stats->histogram[bin], 1u, memory_order_relaxed);
    }
}
