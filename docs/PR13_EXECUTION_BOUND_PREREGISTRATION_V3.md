# PR #13 — execution-bound preregistration V3

This report is generated from the typed `PreregisteredCalibrationExperiment` object. The execution API derives its runtime configuration from the same object and verifies the runtime semantic identity before candidate generation.

- Status: `PREREGISTERED_V3_EXECUTION_BOUND_SEMANTIC_ONLY`
- Correctness baseline: `bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9`
- Candidate policies: `bt709SourceLinear, bt1886ReferenceDisplay`
- Global/local candidates per policy: `128/64`
- Total candidates per policy: `192`
- Shortlist size: `3`
- Seed: `20260912`
- Tune: `NOT_RUN`; Validation: `NOT_RUN`; objective evaluations: `0`

## Definition identities

- PolicyDefinitionHashV3: `d50487b55dfcec609216e51d127b712fbcf9052a27112fb2e7adf21881497e8e`
- PreparationDefinitionHashV3: `672f489e7f51b61d5c4b6d156861c454cbd59f0dd5367c54755d9ad087b98336`
- MetricDefinitionHashV3: `ae62f89f38886eee70765f881716cfcc5f0f6b50a69ca09b2ea2f96131a31f3c`
- SearchAlgorithmDefinitionHash: `d53e3a597eb8a8cee05eb4b967c63d69cc55cc681489643e473e47bbb8e38976`
- SearchDefinitionHashV3: `7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889`
- CorpusDefinitionHash: `NOT_YET_CREATED`
- ExperimentBindingHash: `NOT_YET_CREATED`

## Canonical artifact

```json
{
  "artifactVersion" : 3,
  "corpusDefinitionHash" : "NOT_YET_CREATED",
  "correctnessBaseline" : "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9",
  "experimentBindingHash" : "NOT_YET_CREATED",
  "invalidatedV2SearchDefinitionHash" : "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41",
  "mediaQualification" : "NOT_RUN",
  "metricDefinition" : {
    "configuration" : {
      "absoluteNitsNormalizer" : 1000,
      "additiveLuminanceOffsetNits" : 1,
      "aggregationRules" : [
        "weighted sum using objectiveWeights",
        "video aggregates are the mean of scene metrics",
        "temporal metrics replace the scene temporal contribution exactly once"
      ],
      "blackCrushGeneratedAbsoluteNits" : 0.5,
      "blackCrushGeneratedRatio" : 0.25,
      "blackCrushReferenceThresholdNits" : 1,
      "categoryHighKeyThresholdNits" : 150,
      "categoryHighSaturationChromaThreshold" : 0.08,
      "categoryHighSaturationRatio" : 0.1,
      "categoryHighlightRichUnderreachRatio" : 0.2,
      "categoryLowKeyThresholdNits" : 60,
      "clippingPeakRatio" : 0.999,
      "correlationEpsilon" : 1e-12,
      "correlationLowerBound" : -1,
      "correlationUpperBound" : 1,
      "diffuseMidtoneSourceRange" : {
        "lowerPercentile" : 0.15,
        "upperPercentile" : 0.45
      },
      "emptyAggregateInvalidSampleCount" : 1,
      "emptyAggregateObjective" : 10,
      "failureAlignmentConfidence" : 0.6,
      "failureBlackCrushRatio" : 0.05,
      "failureDiffuseWhiteHighRatio" : 1.2,
      "failureDiffuseWhiteLowRatio" : 0.8,
      "failureHandling" : [
        "non-finite output and invalid paired samples remain observable",
        "invalid metric values use invalidMetricScore and fail the evaluation gate",
        "no failure is silently converted into an empty successful metric"
      ],
      "failureHighlightOvershootRatio" : 0.1,
      "failureHighlightUnderreachRatio" : 0.2,
      "failureHueP95Error" : 0.1,
      "failureMidtoneError" : 0.25,
      "failureReferenceMismatchHue" : 0.2,
      "failureReferenceMismatchLuminance" : 0.4,
      "failureSaturationRatio" : 0.15,
      "failureShadowLiftRatio" : 0.1,
      "failureTemporalFlicker" : 0.08,
      "highChromaThreshold" : 0.08,
      "highlightOvershootAbsoluteNits" : 20,
      "highlightOvershootRatio" : 1.25,
      "highlightUnderreachRatio" : 0.8,
      "hueMeanWeight" : 0.65,
      "hueP95Weight" : 0.35,
      "invalidMetricScore" : 1,
      "metricVersion" : "v2-objective-with-v61-directional-diagnostics",
      "minimumGeneratedChroma" : 0.005,
      "minimumReferenceChroma" : 0.01,
      "nearBlackReferenceRangeFloorNits" : 1,
      "nonFiniteHandling" : "filter only for percentile ordering; paired samples increment invalid count",
      "nonNegativeClampFloor" : 0,
      "nonNegativeClampPolicy" : "ratios, correlations, and penalty metrics clamp at their documented lower bound",
      "normalizationRules" : [
        "mean absolute log luminance error",
        "absolute error divided by absoluteNitsNormalizer",
        "regional values are normalized by region population"
      ],
      "objectiveDirection" : "minimize",
      "objectiveNames" : [
        "luminance",
        "absoluteNits",
        "midtone",
        "diffuseWhite",
        "highlight",
        "shadow",
        "chroma",
        "saturation",
        "hue",
        "temporal",
        "structure",
        "clippingPenalty",
        "blackCrushPenalty",
        "saturationPenalty",
        "invalidPenalty"
      ],
      "objectiveWeights" : {
        "absoluteNits" : 0.03,
        "blackCrushPenalty" : 0.2,
        "chroma" : 0.07,
        "clippingPenalty" : 0.3,
        "diffuseWhite" : 0.12,
        "highlight" : 0.18,
        "hue" : 0.08,
        "invalidPenalty" : 10,
        "luminance" : 0.16,
        "midtone" : 0.08,
        "saturation" : 0.04,
        "saturationPenalty" : 0.1,
        "shadow" : 0.15,
        "structure" : 0.06,
        "temporal" : 0.1
      },
      "percentileFractions" : {
        "p1" : 0.01,
        "p10" : 0.1,
        "p25" : 0.25,
        "p50" : 0.5,
        "p75" : 0.75,
        "p90" : 0.9,
        "p95" : 0.95,
        "p99" : 0.99,
        "p999" : 0.999
      },
      "percentileInterpolation" : "nearest lower order statistic: floor((count - 1) * fraction)",
      "perceptualColorInputMaximumNits" : 10000,
      "perceptualColorInputMinimumNits" : 0,
      "perceptualColorTransformVersion" : "ICTCP-PQ-v1; coefficients fixed in PerceptualColorV2",
      "regionPercentiles" : {
        "diffuseWhite" : {
          "lowerPercentile" : 0.75,
          "upperPercentile" : 0.95
        },
        "highlight" : {
          "lowerPercentile" : 0.9,
          "upperPercentile" : 1
        },
        "midtone" : {
          "lowerPercentile" : 0.1,
          "upperPercentile" : 0.9
        },
        "p0_p1" : {
          "lowerPercentile" : 0,
          "upperPercentile" : 0.01
        },
        "p10_p50" : {
          "lowerPercentile" : 0.1,
          "upperPercentile" : 0.5
        },
        "p1_p10" : {
          "lowerPercentile" : 0.01,
          "upperPercentile" : 0.1
        },
        "p50_p90" : {
          "lowerPercentile" : 0.5,
          "upperPercentile" : 0.9
        },
        "p90_p99" : {
          "lowerPercentile" : 0.9,
          "upperPercentile" : 0.99
        },
        "p99_p100" : {
          "lowerPercentile" : 0.99,
          "upperPercentile" : 1
        },
        "shadow" : {
          "lowerPercentile" : 0,
          "upperPercentile" : 0.1
        }
      },
      "regionalMetricNames" : [
        "shadow",
        "midtone",
        "diffuseWhite",
        "highlight",
        "p0_p1",
        "p1_p10",
        "p10_p50",
        "p50_p90",
        "p90_p99",
        "p99_p100"
      ],
      "saturationDenominatorFloor" : 0.01,
      "saturationOvershootAbsolute" : 0.01,
      "saturationOvershootRatio" : 1.25,
      "saturationUndershootAbsolute" : 0.01,
      "saturationUndershootRatio" : 0.75,
      "semanticVersion" : "v2-metric-semantics-v3",
      "shadowLiftAbsoluteNits" : 2,
      "shadowLiftRatio" : 1.5,
      "signedSemantics" : [
        "signed error is generated minus reference",
        "positive overshoot and negative undershoot remain separate diagnostics",
        "primary objective uses absolute\/log terms and never signed cancellation"
      ],
      "skinMinimumPeakNits" : 1,
      "skinRedBlueSeparation" : 0.12,
      "slopeFloorNits" : 1,
      "specularPercentile" : 0.999,
      "temporalFlickerWeight" : 0.2,
      "temporalHighlightWeight" : 0.35,
      "temporalLuminanceWeight" : 0.45,
      "temporalMetricNames" : [
        "temporal luminance",
        "highlight pumping",
        "temporal flicker",
        "contiguous prepared windows only"
      ]
    },
    "humanReadableDescription" : "V2 objective evaluator consumes the sealed typed metric configuration",
    "metricConfigurationCanonical" : "7ab752868acfc05f75725f89ed3479434b2f296f02a399b62417e31b869be173",
    "semanticVersion" : "sdr-metric-definition-v3"
  },
  "metricDefinitionHashV3" : "ae62f89f38886eee70765f881716cfcc5f0f6b50a69ca09b2ea2f96131a31f3c",
  "objectiveEvaluations" : 0,
  "policyDefinition" : {
    "bt1886ParameterValidationDomain" : [
      "L_B finite and >= 0",
      "L_W finite and > L_B",
      "L_W <= 10000",
      "gamma finite and in (0,10]"
    ],
    "bt1886Parameters" : {
      "blackLuminance" : 0,
      "gamma" : 2.4,
      "whiteLuminance" : 1
    },
    "bt1886ReferenceDisplaySemanticVersion" : "bt1886-reference-display-v3",
    "bt709SourceLinearSemanticVersion" : "bt709-source-linear-v3",
    "candidateList" : [
      "bt709SourceLinear",
      "bt1886ReferenceDisplay"
    ],
    "explicitGammaBehavior" : "metadata gamma finite and > 0; metadata authoritative",
    "explicitGammaSemanticVersion" : "explicit-gamma-v3",
    "linearBehavior" : "encoded signal is already linear; metadata authoritative",
    "linearSemanticVersion" : "linear-source-v3",
    "policyVersion" : "sdr-input-interpretation-policy-v1",
    "sRGBBehavior" : "inverse IEC 61966-2-1 piecewise transfer; metadata authoritative",
    "sRGBSemanticVersion" : "srgb-source-v3",
    "semanticVersion" : "sdr-policy-definition-v3",
    "untaggedFallback" : "assumeBT709SourceLinear",
    "untaggedFallbackSemantics" : [
      "assumeBT709SourceLinear",
      "assumeBT1886ReferenceDisplay",
      "reject"
    ]
  },
  "policyDefinitionHashV3" : "d50487b55dfcec609216e51d127b712fbcf9052a27112fb2e7adf21881497e8e",
  "preparationDefinition" : {
    "configuration" : {
      "acceptedConfidenceThreshold" : 0.6,
      "alignmentConfidenceThreshold" : 0,
      "allowHLGModel" : true,
      "bt1886Parameters" : {
        "blackLuminance" : 0,
        "gamma" : 2.4,
        "whiteLuminance" : 1
      },
      "frameDecoderPolicy" : "FrameReader.auto(avfoundation;ffmpeg-fallback)",
      "hdrPixelFormat" : 2016686640,
      "matcherConfiguration" : {
        "acceptedConfidenceThreshold" : 0.6,
        "edgeMaskWeight" : 0.1,
        "gridHeight" : 36,
        "gridWidth" : 64,
        "localContrastWeight" : 0.1,
        "matcherVersion" : "v6-transfer-invariant-matcher-v3",
        "multiScaleNCCWeight" : 0.25,
        "multiScaleWidths" : [
          64,
          32,
          16
        ],
        "offsetMaximumSeconds" : 2,
        "offsetMinimumSeconds" : -2,
        "offsetStepSeconds" : 0.03333333333333333,
        "preparationAlgorithmVersion" : "v6-prepared-evaluation-v6",
        "rankWeight" : 0.3,
        "signedGradientWeight" : 0.25
      },
      "matcherConfigurationHash" : "af4e7b3bc2aa24bc1cf178fea16cb8b6c0fc032a1fb9759dd6d0a28b3c426a52",
      "matcherVersion" : "v6-transfer-invariant-matcher-v3",
      "maxDecodedFrames" : 128,
      "maxFramesPerScene" : 8,
      "pathResolutionPolicy" : "manifest-resolved-once;repository-relative-plan-paths",
      "preparationAlgorithmVersion" : "v6-prepared-evaluation-v6",
      "proxyWidth" : 320,
      "referenceDecoderPolicy" : "HDRReferenceDecoder.linear-reference-v1",
      "referenceTargetPeakNits" : 1000,
      "sceneSelectionPolicy" : "SceneDetector.v6;sequencePosition-domain",
      "sdrInterpretationPolicy" : "bt709SourceLinear",
      "sdrInterpretationPolicyHash" : "4a378248cf08d29b55ac96956ef36ed85f8e624c1231e2d5e389485e934a3ccb",
      "sdrInterpretationPolicyVersion" : "sdr-input-interpretation-policy-v1",
      "sdrPixelFormat" : 875704438,
      "temporalFramesPerSecond" : 30,
      "temporalMinimumFrameCount" : 8,
      "temporalSelectionPolicy" : "anchor=max-confidence;start=anchorTime-0.05;paired-contiguous-window",
      "temporalTargetFrameCount" : 16,
      "temporalWarmupFrameCount" : 1,
      "untaggedSDRFallback" : "assumeBT709SourceLinear",
      "version" : "v6-prepared-evaluation-plan-v6-sdr-interpretation-policy"
    },
    "failurePolicy" : [
      "decode, alignment, scene, temporal, path, or hash failure rejects the plan",
      "no implicit frame selection or policy fallback at evaluator entry",
      "non-finite preparation values reject before plan sealing"
    ],
    "humanReadableDescription" : "V6 preparation uses the sealed typed configuration and matcher object",
    "matcherConfigurationCanonical" : "af4e7b3bc2aa24bc1cf178fea16cb8b6c0fc032a1fb9759dd6d0a28b3c426a52",
    "policyConfigurations" : {
      "bt1886ReferenceDisplay" : {
        "acceptedConfidenceThreshold" : 0.6,
        "alignmentConfidenceThreshold" : 0,
        "allowHLGModel" : true,
        "bt1886Parameters" : {
          "blackLuminance" : 0,
          "gamma" : 2.4,
          "whiteLuminance" : 1
        },
        "frameDecoderPolicy" : "FrameReader.auto(avfoundation;ffmpeg-fallback)",
        "hdrPixelFormat" : 2016686640,
        "matcherConfiguration" : {
          "acceptedConfidenceThreshold" : 0.6,
          "edgeMaskWeight" : 0.1,
          "gridHeight" : 36,
          "gridWidth" : 64,
          "localContrastWeight" : 0.1,
          "matcherVersion" : "v6-transfer-invariant-matcher-v3",
          "multiScaleNCCWeight" : 0.25,
          "multiScaleWidths" : [
            64,
            32,
            16
          ],
          "offsetMaximumSeconds" : 2,
          "offsetMinimumSeconds" : -2,
          "offsetStepSeconds" : 0.03333333333333333,
          "preparationAlgorithmVersion" : "v6-prepared-evaluation-v6",
          "rankWeight" : 0.3,
          "signedGradientWeight" : 0.25
        },
        "matcherConfigurationHash" : "af4e7b3bc2aa24bc1cf178fea16cb8b6c0fc032a1fb9759dd6d0a28b3c426a52",
        "matcherVersion" : "v6-transfer-invariant-matcher-v3",
        "maxDecodedFrames" : 128,
        "maxFramesPerScene" : 8,
        "pathResolutionPolicy" : "manifest-resolved-once;repository-relative-plan-paths",
        "preparationAlgorithmVersion" : "v6-prepared-evaluation-v6",
        "proxyWidth" : 320,
        "referenceDecoderPolicy" : "HDRReferenceDecoder.linear-reference-v1",
        "referenceTargetPeakNits" : 1000,
        "sceneSelectionPolicy" : "SceneDetector.v6;sequencePosition-domain",
        "sdrInterpretationPolicy" : "bt1886ReferenceDisplay",
        "sdrInterpretationPolicyHash" : "8dcb0bf2735051ec4bc1c24a3d469269708d3f7e91826e5a0dfb698d5a017a99",
        "sdrInterpretationPolicyVersion" : "sdr-input-interpretation-policy-v1",
        "sdrPixelFormat" : 875704438,
        "temporalFramesPerSecond" : 30,
        "temporalMinimumFrameCount" : 8,
        "temporalSelectionPolicy" : "anchor=max-confidence;start=anchorTime-0.05;paired-contiguous-window",
        "temporalTargetFrameCount" : 16,
        "temporalWarmupFrameCount" : 1,
        "untaggedSDRFallback" : "assumeBT709SourceLinear",
        "version" : "v6-prepared-evaluation-plan-v6-sdr-interpretation-policy"
      },
      "bt709SourceLinear" : {
        "acceptedConfidenceThreshold" : 0.6,
        "alignmentConfidenceThreshold" : 0,
        "allowHLGModel" : true,
        "bt1886Parameters" : {
          "blackLuminance" : 0,
          "gamma" : 2.4,
          "whiteLuminance" : 1
        },
        "frameDecoderPolicy" : "FrameReader.auto(avfoundation;ffmpeg-fallback)",
        "hdrPixelFormat" : 2016686640,
        "matcherConfiguration" : {
          "acceptedConfidenceThreshold" : 0.6,
          "edgeMaskWeight" : 0.1,
          "gridHeight" : 36,
          "gridWidth" : 64,
          "localContrastWeight" : 0.1,
          "matcherVersion" : "v6-transfer-invariant-matcher-v3",
          "multiScaleNCCWeight" : 0.25,
          "multiScaleWidths" : [
            64,
            32,
            16
          ],
          "offsetMaximumSeconds" : 2,
          "offsetMinimumSeconds" : -2,
          "offsetStepSeconds" : 0.03333333333333333,
          "preparationAlgorithmVersion" : "v6-prepared-evaluation-v6",
          "rankWeight" : 0.3,
          "signedGradientWeight" : 0.25
        },
        "matcherConfigurationHash" : "af4e7b3bc2aa24bc1cf178fea16cb8b6c0fc032a1fb9759dd6d0a28b3c426a52",
        "matcherVersion" : "v6-transfer-invariant-matcher-v3",
        "maxDecodedFrames" : 128,
        "maxFramesPerScene" : 8,
        "pathResolutionPolicy" : "manifest-resolved-once;repository-relative-plan-paths",
        "preparationAlgorithmVersion" : "v6-prepared-evaluation-v6",
        "proxyWidth" : 320,
        "referenceDecoderPolicy" : "HDRReferenceDecoder.linear-reference-v1",
        "referenceTargetPeakNits" : 1000,
        "sceneSelectionPolicy" : "SceneDetector.v6;sequencePosition-domain",
        "sdrInterpretationPolicy" : "bt709SourceLinear",
        "sdrInterpretationPolicyHash" : "4a378248cf08d29b55ac96956ef36ed85f8e624c1231e2d5e389485e934a3ccb",
        "sdrInterpretationPolicyVersion" : "sdr-input-interpretation-policy-v1",
        "sdrPixelFormat" : 875704438,
        "temporalFramesPerSecond" : 30,
        "temporalMinimumFrameCount" : 8,
        "temporalSelectionPolicy" : "anchor=max-confidence;start=anchorTime-0.05;paired-contiguous-window",
        "temporalTargetFrameCount" : 16,
        "temporalWarmupFrameCount" : 1,
        "untaggedSDRFallback" : "assumeBT709SourceLinear",
        "version" : "v6-prepared-evaluation-plan-v6-sdr-interpretation-policy"
      }
    },
    "preparationConfigurationCanonical" : "aa0384c382e655c8f8126fa6f795e4b5a1f283838ea1d3f6f929db2f224916dc",
    "semanticVersion" : "sdr-preparation-definition-v3"
  },
  "preparationDefinitionHashV3" : "672f489e7f51b61d5c4b6d156861c454cbd59f0dd5367c54755d9ad087b98336",
  "preregistrationInvalidated" : false,
  "retiredV1SearchDefinitionHash" : "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608",
  "searchAlgorithmDefinitionHash" : "d53e3a597eb8a8cee05eb4b967c63d69cc55cc681489643e473e47bbb8e38976",
  "searchDefinition" : {
    "failurePolicy" : [
      "infrastructure failure before metric exposure may rerun the same sealed configuration",
      "metric exposure followed by failure invalidates this selection cycle",
      "no threshold, metric, policy, or search-space change after Validation exposure"
    ],
    "hardGates" : [
      "finite outputs and no GPU error",
      "transfer, range, and metadata resolution match the selected policy",
      "transform monotonicity and exact black\/white anchors",
      "temporal sequence and precision checks pass"
    ],
    "metricDefinitionHashV3" : "ae62f89f38886eee70765f881716cfcc5f0f6b50a69ca09b2ea2f96131a31f3c",
    "parameterBounds" : {
      "contrastStrength" : [
        0.5,
        0.95
      ],
      "highlightStrength" : [
        0.42,
        0.86
      ],
      "paperWhiteNits" : [
        190,
        245
      ],
      "peakNits" : [
        900,
        1500
      ],
      "saturationCompensation" : [
        0.1,
        0.5
      ],
      "shadowProtection" : [
        0.05,
        1
      ],
      "temporalStability" : [
        0.2,
        0.98
      ]
    },
    "parameterRepresentation" : "finite Float32 runtime values; canonical decimal JSON; fixed parameter order",
    "policyCandidates" : [
      "bt709SourceLinear",
      "bt1886ReferenceDisplay"
    ],
    "policyDefinitionHashV3" : "d50487b55dfcec609216e51d127b712fbcf9052a27112fb2e7adf21881497e8e",
    "preparationDefinitionHashV3" : "672f489e7f51b61d5c4b6d156861c454cbd59f0dd5367c54755d9ad087b98336",
    "safetyGates" : [
      "no unexpected fallback",
      "no range mismatch",
      "no clipping or near-black safety violation",
      "no invalid paired sample"
    ],
    "safetyThresholds" : {
      "catastrophicSceneRegression" : 0.2,
      "frozenMinimumImprovement" : 0.05,
      "frozenPerVideoRegressionTolerance" : 0.02,
      "groupedObjectiveRelativeTolerance" : 0.05,
      "groupedTemporalFlickerRelativeTolerance" : 0.05,
      "highlightRelativeTolerance" : 0.05,
      "hueRelativeTolerance" : 0.05,
      "midtoneRelativeTolerance" : 0.05,
      "runtime" : {
        "absoluteToleranceMilliseconds" : 0.1,
        "cpuP95RelativeTolerance" : 0.15,
        "gpuP50RelativeTolerance" : 0.08,
        "gpuP95RelativeTolerance" : 0.1,
        "height" : 1080,
        "measuredFrames" : 300,
        "p50Fraction" : 0.5,
        "p95Fraction" : 0.95,
        "p99Fraction" : 0.99,
        "warmupFrames" : 30,
        "width" : 1920
      },
      "sensitivityShadowDeltaMinimum" : 0.002,
      "sensitivityShadowMonotonicTolerance" : 0.01,
      "sensitivityTemporalDeltaMinimum" : 1e-05,
      "shadowErrorTolerance" : 0.01,
      "shadowLiftTolerance" : 0.005,
      "temporalFlickerAbsoluteTolerance" : 0.002,
      "temporalFlickerRelativeTolerance" : 0.05,
      "validationHighlightAbsoluteTolerance" : 0.005,
      "validationHueAbsoluteTolerance" : 0.002,
      "validationMidtoneAbsoluteTolerance" : 0.005,
      "zeroTolerance" : 1e-06
    },
    "searchAlgorithmDefinition" : {
      "candidateOrdering" : "global then local; within phase ascending candidate index; selection sorts by sealed objective\/tie-break",
      "duplicateHandling" : "retain generated records; deterministic sort and lexicographic parameter vector resolve ties",
      "globalCandidateCount" : 128,
      "globalHaltonBases" : [
        2,
        3,
        5,
        7,
        11,
        13,
        17
      ],
      "globalParentCount" : 8,
      "globalSamplingDistribution" : "Halton; one point per index; affine map into each parameter bound",
      "localCandidateCount" : 64,
      "localHaltonBases" : [
        19,
        23,
        29,
        31,
        37,
        41,
        43
      ],
      "localNeighborhoodRadius" : 0.1,
      "localRefinementParentSelection" : "top 8 gate-passing global candidates, cyclic by local candidate index",
      "localSamplingDistribution" : "Halton neighborhood around selected global parent; affine clamp into each bound",
      "phaseOrdering" : [
        "sensitivity",
        "global",
        "local"
      ],
      "prngImplementationVersion" : "none; deterministic Halton only",
      "seedDerivation" : "Halton index = candidate index + 1 + (search seed modulo seedIndexModulus)",
      "seedIndexModulus" : 104729,
      "semanticVersion" : "sdr-search-algorithm-definition-v3",
      "sensitivityProbeValues" : [
        0,
        0.25,
        0.5,
        0.75,
        1
      ],
      "totalCandidatesPerPolicy" : 192
    },
    "searchAlgorithmDefinitionHash" : "d53e3a597eb8a8cee05eb4b967c63d69cc55cc681489643e473e47bbb8e38976",
    "searchBudgetPerPolicy" : 192,
    "seed" : 20260912,
    "selectionOrdering" : [
      "all hard correctness gates pass",
      "all safety gates pass",
      "primary existing objective is minimized",
      "temporal stability, clipping, and near-black safety break ties"
    ],
    "semanticVersion" : "sdr-search-definition-v3",
    "shortlistSize" : 3,
    "splitSeed" : 92,
    "tieBreakRule" : [
      "lower objective",
      "lower temporal error",
      "lower clipping ratio",
      "lower near-black contrast loss",
      "lexicographically smallest canonical parameter vector"
    ]
  },
  "searchDefinitionHashV3" : "7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889",
  "status" : "PREREGISTERED_V3_EXECUTION_BOUND_SEMANTIC_ONLY",
  "tune" : "NOT_RUN",
  "validation" : "NOT_RUN"
}
```